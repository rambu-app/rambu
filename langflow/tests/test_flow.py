import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FLOW_PATH = ROOT / "langflow" / "flows" / "Rambu.json"
PROMPT_PATH = ROOT / "langflow" / "prompts" / "system_prompt.md"


def test_prompt_defines_risk_contract_and_safety_rules() -> None:
    prompt = PROMPT_PATH.read_text()

    assert "risk_level" in prompt
    assert "signals" in prompt
    assert "evidence" in prompt
    assert "explanation" in prompt
    assert "recommended_action" in prompt
    assert "low | needs_review | high_risk" in prompt
    assert "impersonation | urgency | secret_code | transfer | remote_app" in prompt
    assert "kutipan persis" in prompt
    assert "low` wajib memiliki `signals` dan `evidence` kosong" in prompt
    assert "Jangan pernah menyatakan seseorang pasti penipu" in prompt
    assert "Nilai maksud ucapan, bukan kemunculan kata kunci" in prompt
    assert "peringatan, larangan, penolakan, atau cerita tentang kejadian lampau" in prompt
    assert "Jika ada permintaan berisiko aktif di bagian lain" in prompt
    assert "karakter demi karakter" in prompt
    assert "Susun `evidence` terlebih dahulu" in prompt
    assert "harus sama persis dengan gabungan unik" in prompt
    assert "JSON" in prompt
    assert "indicators" not in prompt


def test_prompt_uses_selected_language_for_analysis_and_user_facing_text() -> None:
    prompt = PROMPT_PATH.read_text()

    assert "`language`: `id` atau `en`" in prompt
    assert "gunakan aturan dan contoh Bahasa Inggris" in prompt
    assert "`explanation` dan `recommended_action`" in prompt
    assert "bahasa yang ditentukan oleh `language`" in prompt
    assert "seluruh teks harus dalam Bahasa Indonesia" not in prompt


def test_exported_flow_is_minimal_and_secret_free() -> None:
    flow = json.loads(FLOW_PATH.read_text())
    nodes = flow["data"]["nodes"]
    node_types = {node["id"].split("-")[0] for node in nodes}
    serialized = FLOW_PATH.read_text()

    assert flow["name"] == "Rambu"
    assert flow["endpoint_name"] == "rambu"
    assert len(nodes) == 4
    assert node_types == {"ChatInput", "Prompt", "LanguageModelComponent", "ChatOutput"}
    assert len(flow["data"]["edges"]) == 3
    assert "openai/gpt-4o-mini" in serialized
    assert "sk-or-" not in serialized
    assert "OPENROUTER_API_KEY=" not in serialized


def test_exported_prompt_matches_source() -> None:
    flow = json.loads(FLOW_PATH.read_text())
    prompt_node = next(node for node in flow["data"]["nodes"] if node["id"].startswith("Prompt-"))
    embedded = prompt_node["data"]["node"]["template"]["template"]["value"]

    assert embedded == PROMPT_PATH.read_text()


def test_exported_prompt_preserves_literal_json_schema() -> None:
    flow = json.loads(FLOW_PATH.read_text())
    prompt_node = next(node for node in flow["data"]["nodes"] if node["id"].startswith("Prompt-"))
    template = prompt_node["data"]["node"]["template"]

    assert '"risk_level"' in template["template"]["value"]
    assert template["use_double_brackets"]["value"] is True
