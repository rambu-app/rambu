# Rambu

Rambu warns older parents about scam calls. An ESP32 puck next to the iPhone starts recording when a call rings, the Mac backend transcribes the audio and asks Langflow for a risk check, and the parent and guardians get a push warning.

```
iPhone call ──BLE──▶ ESP32 puck ──Wi-Fi──▶ your public HTTPS address ──tunnel──▶ Mac backend ──▶ Langflow
```

## Requirements

- Mac with Xcode 26, XcodeGen, Python 3.12, `uv`, `cloudflared`, `arduino-cli`
- iPhone on iOS 26 (a second iPhone for the guardian)
- Puck: ESP32 DevKit V1, INMP441 mic, 6 female–female jumpers
- OpenRouter API key, Apple push key (`.p8`), Cloudflare tunnel token

## 1. Langflow

```bash
uv venv langflow/.venv --python 3.12 && source langflow/.venv/bin/activate
uv pip install 'langflow>=1.12,<1.13'        # first time only
langflow run --host 127.0.0.1 --port 7861
```

Create an API key at <http://127.0.0.1:7861> → **Settings → Langflow API Keys**.

## 2. Backend

```bash
cp backend/.env.example backend/.env          # then fill LANGFLOW_*, OPENROUTER_API_KEY, APNS_*
uv sync --project backend
uv run --project backend python langflow/scripts/bootstrap_flow.py   # prints "Langflow flow ready: Rambu"
uv run --project backend uvicorn rambu_api.app:app --host 0.0.0.0 --port 8001 --env-file backend/.env
```

Apps run from Xcode use sandbox push. For them set `APNS_ENVIRONMENT=sandbox` with the sandbox key; TestFlight builds need `production`.

## 3. Public address

The app and puck talk to one public HTTPS address, set in `RambuServer.url` (`ios/RambuPuck/Services/PilotAPI.swift`). The puck gets it from the app. Point a Cloudflare tunnel route for that hostname to `http://localhost:8001`.

```bash
cloudflared tunnel run --token-file ~/.config/rambu/cloudflare-tunnel-token
```

## 4. iPhone app

```bash
cd ios && xcodegen generate && open RambuPuck.xcodeproj
```

Run on the iPhone, enter the parent's name, and finish the practice call. Then tap **Hubungkan keluarga** on the home screen and create a family. Guardians join with its six-digit code.

### Languages

Rambu supports Indonesian and English. A fresh installation follows the iPhone's preferred language when it is Indonesian or English, and the selection can be changed during onboarding or later from **Profile → Language** without resetting the family or call history.

The selected language also applies to practice calls, spoken guidance, dates and invitations, scam warnings, family decisions, and operational errors. English protection sessions use English transcription and analysis prompts while retaining bilingual safeguards for explicit requests for OTPs, PINs, passwords, and other secrets. Push tokens store the language of their device, so members of the same family can receive personalized warnings and decisions in different languages.

Translations are maintained centrally in the iOS String Catalog at `ios/RambuPuck/Resources/Localizable.xcstrings`; privacy descriptions live in `ios/RambuPuck/Resources/InfoPlist.xcstrings`. User-entered names and caller transcripts are never translated.

## 5. Puck

**Wire** the INMP441 to the ESP32: SCK→D32, WS→D25, SD→D33, L/R→GND, VDD→3V3, GND→GND.

**Flash** it (once, nothing to edit):

```bash
arduino-cli core install esp32:esp32
arduino-cli lib install ArduinoJson NimBLE-Arduino@2.2.3
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app hardware/puck-firmware
arduino-cli upload  --fqbn esp32:esp32:esp32:PartitionScheme=huge_app -p /dev/cu.usbserial-0001 hardware/puck-firmware
```

**Connect** it. Power the puck from the iPhone or a charger. In the app, open the **Puck** tab → **Pasangkan puck** → **Pair**, allow notifications, then enter the Wi-Fi under **Wi-Fi puck**. The app sends the puck its Wi-Fi, server address and family token over Bluetooth.

## 6. Test

Close Rambu, call the iPhone, answer on speaker, and say something scam-like. The puck's blue LED turns on while it records, a warning arrives within ~5–10 s, and the puck stops when you hang up. The call appears in **Riwayat**.

To see the puck's log, plug it into the Mac: `arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200`.
