# Rambu

Rambu detects an active iPhone call, records its loudspeaker audio through an external puck, transcribes it, and asks Langflow to assess scam risk. For now, the Mac runs as the temporary puck. Rambu has no analysis fallback: configuration and processing failures are shown as errors.

The iPhone does not record call audio. Keep Rambu open during the call and place the Mac near the phone's loudspeaker. One iPhone is enough; a second iPhone is only needed for guardian alerts.

## Requirements

- macOS with Xcode 26 and XcodeGen
- A physical iPhone running iOS 26
- Python 3.12 and `uv`
- Langflow 1.12.x
- OpenRouter and Langflow API keys
- Mac and iPhone on the same Wi-Fi network

Run every command below from the repository root unless stated otherwise.

## Remote Demo in One Terminal

For the two-iPhone TestFlight demo, validate the local setup first:

```bash
./tools/run_remote_demo.sh --check
```

Then start Langflow, the backend, a temporary public Cloudflare tunnel, and the Mac puck from one terminal:

```bash
./tools/run_remote_demo.sh
```

The launcher reuses healthy Langflow or backend processes if they are already running. Otherwise it starts them, verifies the Langflow flow, and prints a temporary `https://…trycloudflare.com` server URL. Enter that URL under **Profile → Pilot keluarga** on both iPhones. Create the family on the parent iPhone, then enter its six-digit invitation code in the terminal when prompted.

During a call, the same terminal prints a masked transcription line for every processed audio chunk, for example `🎙 Heard [chunk 2]: Tolong berikan [KODE].`. An empty chunk prints `(no speech detected)`, confirming that audio processing is still active. Sensitive values are masked by the backend before they reach this display.

Keep the terminal open during the demo and press `Ctrl+C` afterward. The launcher stops only the processes it started and prints the location of its diagnostic logs. A Quick Tunnel URL changes on every run and anyone with the URL can reach the demo backend while it is active, so use it only for controlled testing.

### TestFlight rollout and two-device acceptance

Install the same new TestFlight build on both the parent iPhone and Richard's iPhone before validating synchronized history. Backend-owned yellow/red guardian notifications become available as soon as the new backend is running and the guardian device has registered its push token; the new app build is required for both devices to display the shared green/yellow/red/gray history.

Run this acceptance matrix with the parent app backgrounded for the yellow, red, and escalation cases:

| Case | Parent and guardian history | Guardian notification |
|---|---|---|
| Safe call, then end | Green **Aman** on both phones | None |
| Warning call, then end | Yellow **Bahaya** on both phones | One warning |
| High-confidence call, then end | Red **Bahaya** on both phones | One danger warning |
| One call escalates yellow → red | Final red **Bahaya** on both phones | One at yellow and one at red; no duplicates |
| No-speech call, then end | Gray **Tidak dapat dinilai** on both phones | None |
| Call remains active, then ends | Absent while active; final state appears on both phones after ending | Only if risk reaches yellow/red |

## Run the App

### 1. Start Langflow

```bash
uv venv langflow/.venv --python 3.12
source langflow/.venv/bin/activate
uv pip install 'langflow>=1.12,<1.13'
langflow run --host 127.0.0.1 --port 7861
```

For later runs, activate the existing environment and start Langflow:

```bash
source langflow/.venv/bin/activate
langflow run --host 127.0.0.1 --port 7861
```

Open <http://127.0.0.1:7861>, then:

1. Select your profile icon, then open **Settings → Langflow API Keys → Add New**.
2. Create a new key and copy its complete value immediately. The key must come from this running Langflow instance.

Keep this terminal running.

### 2. Start the Backend

If `backend/.env` does not exist:

```bash
cp backend/.env.example backend/.env
```

Set these values in `backend/.env`:

```dotenv
LANGFLOW_URL=http://127.0.0.1:7861
LANGFLOW_FLOW_ID=rambu
LANGFLOW_API_KEY=<your-langflow-api-key>
OPENROUTER_API_KEY=<your-openrouter-api-key>
```

Use the Langflow key created in step 1 for `LANGFLOW_API_KEY`. The OpenRouter key goes only in `OPENROUTER_API_KEY`; the IBM key is not used by the runtime.

Install the backend dependencies, then automatically import, configure, and verify the Rambu flow:

```bash
uv sync --project backend
uv run --project backend python langflow/scripts/bootstrap_flow.py
```

The command must print `Langflow flow ready: Rambu`. It injects the OpenRouter key only into the upload sent to your local Langflow; it does not write the key into `Rambu.json`.

Start the backend:

```bash
uv run --project backend uvicorn rambu_api.app:app \
  --host 0.0.0.0 --port 8000 --env-file backend/.env
```

It is ready when <http://127.0.0.1:8000/health> returns `{"status":"ready"}`. Keep this terminal running.

### 3. Run the iPhone App

Find the Mac's Wi-Fi IP address:

```bash
ipconfig getifaddr en0
```

Generate and open the Xcode project:

```bash
cd ios
xcodegen generate
open RambuPuck.xcodeproj
```

In Xcode:

1. Select your development team for both app targets.
2. Select the connected physical iPhone.
3. Press **Run**.

In Rambu on the iPhone:

1. Complete onboarding as the parent.
2. Open **Profile → Pilot keluarga**.
3. Set the server URL to `http://<MAC-IP>:8000`.
4. Create the family and note its six-digit invitation code.

### 4. Connect the Puck

Return to the repository root in a new terminal. Replace the IP and invitation code:

```bash
export RAMBU_SERVER_URL='http://<MAC-IP>:8000'
export RAMBU_PUCK_TOKEN="$(swift run --package-path tools/rambu-puck-agent \
  rambu-puck-agent pair --code 123456 --name 'Mac puck')"
swift run --package-path tools/rambu-puck-agent rambu-puck-agent listen
```

Allow microphone access when macOS asks. Keep this terminal running.

### 5. Test a Call

1. Keep Rambu open on the iPhone.
2. Place or receive a real call.
3. Turn on the iPhone loudspeaker and keep the Mac nearby.
4. Confirm the app progresses from call detected, to listening, to an assessment or an explicit error.

## Troubleshooting

| Problem | Fix |
|---|---|
| `langflow: command not found` | Activate `langflow/.venv`. If it does not exist, run all first-time commands in step 1. |
| Bootstrap reports a missing variable | Set all four required values shown in step 2, then run the bootstrap command again. |
| Backend exits with Langflow `HTTP 403` | Create a new key in the currently running Langflow under **Settings → Langflow API Keys**, copy it completely into `backend/.env`, then restart the backend. |
| Backend exits with Langflow `HTTP 404` | Run the bootstrap command in step 2 and confirm that it prints `Langflow flow ready: Rambu`. |
| Backend exits during startup | Check that Langflow is running, all three `LANGFLOW_*` values are correct, and the imported flow works in Langflow. |
| iPhone cannot reach the backend | Use the Mac's Wi-Fi IP, not `127.0.0.1`, and keep both devices on the same network. |
| Call is detected but remains waiting for the puck | Keep the puck `listen` command running and pair it with the current family invitation code. |
| No call is detected | Use a physical iPhone, keep Rambu open, and grant requested permissions. |
