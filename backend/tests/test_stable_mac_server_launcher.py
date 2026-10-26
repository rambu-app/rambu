from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = REPOSITORY_ROOT / "tools" / "run_stable_mac_server.sh"


def add_fake_command(bin_directory: Path, name: str, body: str = "exit 0") -> None:
    command = bin_directory / name
    command.write_text(f"#!/usr/bin/env bash\nset -eu\n{body}\n")
    command.chmod(0o755)


def prepare_launcher(tmp_path: Path) -> tuple[Path, dict[str, str], Path, Path]:
    repository = tmp_path / "repository"
    tools = repository / "tools"
    backend = repository / "backend"
    langflow_bin = repository / "langflow" / ".venv" / "bin"
    app = repository / "build" / "Rambu Puck.app"
    tools.mkdir(parents=True)
    backend.mkdir()
    langflow_bin.mkdir(parents=True)
    app.mkdir(parents=True)

    launcher = tools / LAUNCHER.name
    shutil.copy2(LAUNCHER, launcher)

    private_key = tmp_path / "AuthKey_TEST.p8"
    private_key.write_text("test-apns-private-key")
    (backend / ".env").write_text(
        "LANGFLOW_URL=http://127.0.0.1:7861\n"
        "LANGFLOW_FLOW_ID=rambu\n"
        "LANGFLOW_API_KEY=langflow-SENTINEL\n"
        "OPENROUTER_API_KEY=openrouter-SENTINEL\n"
        "APNS_TEAM_ID=TEAM123\n"
        "APNS_KEY_ID=KEY123\n"
        f"APNS_PRIVATE_KEY_PATH={private_key}\n"
        "APNS_BUNDLE_ID=id.rambu.puck\n"
        "APNS_ENVIRONMENT=production\n"
    )
    langflow = langflow_bin / "langflow"
    langflow.write_text("#!/usr/bin/env bash\nexit 0\n")
    langflow.chmod(0o755)

    token_file = tmp_path / "cloudflare-tunnel-token"
    token_file.write_text("tunnel-token-SENTINEL\n")
    token_file.chmod(0o600)

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for command in ("uv", "cloudflared", "curl", "open"):
        add_fake_command(fake_bin, command)

    command_log = tmp_path / "commands.log"
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{fake_bin}:{environment['PATH']}",
            "RAMBU_TUNNEL_TOKEN_FILE": str(token_file),
            "RAMBU_STABLE_LOG_DIRECTORY": str(tmp_path / "logs"),
            "RAMBU_TEST_COMMAND_LOG": str(command_log),
            "RAMBU_HEALTH_ATTEMPTS": "3",
            "RAMBU_HEALTH_INTERVAL": "0",
        }
    )
    return launcher, environment, token_file, command_log


def run_launcher(
    launcher: Path,
    environment: dict[str, str],
    *arguments: str,
    timeout: int = 10,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(launcher), *arguments],
        cwd=launcher.parents[1],
        env=environment,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def test_help_explains_the_stable_mac_workflow() -> None:
    result = subprocess.run(
        ["bash", str(LAUNCHER), "--help"],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "run_stable_mac_server.sh" in result.stdout
    assert "rambu-api.sfatimah.com" in result.stdout
    assert "named Cloudflare Tunnel" in result.stdout


def test_check_rejects_a_missing_tunnel_token_without_printing_secrets(
    tmp_path: Path,
) -> None:
    launcher, environment, token_file, _ = prepare_launcher(tmp_path)
    token_file.unlink()

    result = run_launcher(launcher, environment, "--check")

    assert result.returncode != 0
    assert "Cloudflare tunnel token file is missing" in result.stderr
    assert "SENTINEL" not in result.stdout + result.stderr


def test_check_rejects_an_insecure_tunnel_token_file(tmp_path: Path) -> None:
    launcher, environment, token_file, _ = prepare_launcher(tmp_path)
    token_file.chmod(0o644)

    result = run_launcher(launcher, environment, "--check")

    assert result.returncode != 0
    assert "must only be readable by its owner" in result.stderr
    assert "chmod 600" in result.stderr


def test_check_requires_the_packaged_menu_app(tmp_path: Path) -> None:
    launcher, environment, _, _ = prepare_launcher(tmp_path)
    (launcher.parents[1] / "build" / "Rambu Puck.app").rmdir()

    result = run_launcher(launcher, environment, "--check")

    assert result.returncode != 0
    assert "Rambu Puck.app is missing" in result.stderr
    assert "package_rambu_puck_controller.sh" in result.stderr


def test_stable_launcher_uses_named_tunnel_and_opens_menu_app(tmp_path: Path) -> None:
    launcher, environment, token_file, command_log = prepare_launcher(tmp_path)
    fake_bin = Path(environment["PATH"].split(":", 1)[0])
    backend_ready = tmp_path / "backend.ready"
    environment["RAMBU_TEST_BACKEND_READY"] = str(backend_ready)

    add_fake_command(
        fake_bin,
        "curl",
        'case "$*" in\n'
        '  *"127.0.0.1:7861/health"*) exit 0 ;;\n'
        '  *"127.0.0.1:8000/health"*) printf \'%s\\n\' \'{"status":"ok","service":"summon-interviewer"}\'; exit 0 ;;\n'
        '  *"127.0.0.1:8001/health"*)\n'
        '    if test -f "$RAMBU_TEST_BACKEND_READY"; then\n'
        '      printf \'%s\\n\' \'{"status":"ready"}\'\n'
        '    else\n'
        '      printf \'%s\\n\' \'{"status":"ok","service":"not-rambu"}\'\n'
        '    fi ;;\n'
        '  *"rambu-api.sfatimah.com/health"*) printf \'%s\\n\' \'{"status":"ready"}\'; exit 0 ;;\n'
        '  *) exit 1 ;;\n'
        "esac",
    )
    add_fake_command(
        fake_bin,
        "uv",
        'printf "uv %s\\n" "$*" >> "$RAMBU_TEST_COMMAND_LOG"\n'
        'case " $* " in\n'
        '  *" python langflow/scripts/bootstrap_flow.py "*) exit 0 ;;\n'
        '  *" uvicorn rambu_api.app:app "*)\n'
        '    touch "$RAMBU_TEST_BACKEND_READY"\n'
        "    trap 'exit 0' TERM INT\n"
        '    while :; do sleep 1; done ;;\n'
        '  *) exit 2 ;;\n'
        "esac",
    )
    add_fake_command(
        fake_bin,
        "cloudflared",
        'printf "cloudflared %s\\n" "$*" >> "$RAMBU_TEST_COMMAND_LOG"\n'
        "trap 'exit 0' TERM INT\n"
        "sleep 0.2",
    )
    add_fake_command(
        fake_bin,
        "open",
        'printf "open %s\\n" "$*" >> "$RAMBU_TEST_COMMAND_LOG"\n'
        "exit 0",
    )

    result = run_launcher(launcher, environment)

    assert result.returncode == 0
    commands = command_log.read_text()
    assert f"--token-file {token_file}" in commands
    assert "tunnel --no-autoupdate run" in commands
    assert "--url" not in commands
    assert "trycloudflare.com" not in commands
    assert "uvicorn rambu_api.app:app --host 127.0.0.1 --port 8001" in commands
    assert "Rambu Puck.app" in commands
    assert "pair --code" not in commands
    assert "rambu-puck-agent listen" not in commands
    assert "https://rambu-api.sfatimah.com" in result.stdout
    assert "SENTINEL" not in result.stdout + result.stderr


def test_public_health_failure_stops_before_opening_the_menu_app(tmp_path: Path) -> None:
    launcher, environment, _, command_log = prepare_launcher(tmp_path)
    fake_bin = Path(environment["PATH"].split(":", 1)[0])
    add_fake_command(
        fake_bin,
        "curl",
        'case "$*" in\n'
        '  *"127.0.0.1:7861/health"*) exit 0 ;;\n'
        '  *"127.0.0.1:8001/health"*) printf \'%s\\n\' \'{"status":"ready"}\'; exit 0 ;;\n'
        '  *) printf "%s\\n" "not reachable" >&2; exit 22 ;;\n'
        "esac",
    )
    add_fake_command(
        fake_bin,
        "uv",
        'case " $* " in\n'
        '  *" python langflow/scripts/bootstrap_flow.py "*) exit 0 ;;\n'
        '  *) exit 2 ;;\n'
        "esac",
    )
    add_fake_command(
        fake_bin,
        "cloudflared",
        "trap 'exit 0' TERM INT\n"
        "while :; do sleep 1; done",
    )
    add_fake_command(
        fake_bin,
        "open",
        'printf "open %s\\n" "$*" >> "$RAMBU_TEST_COMMAND_LOG"',
    )

    result = run_launcher(launcher, environment)

    assert result.returncode != 0
    assert "Timed out waiting for public backend" in result.stderr
    assert not command_log.exists()
