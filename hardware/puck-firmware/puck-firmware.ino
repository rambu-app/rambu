#include <WiFi.h>
#include <Preferences.h>
#include <WiFiClientSecure.h>
#include <ESP_I2S.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <time.h>
#include <esp_bt.h>

const int MIC_SCK = 32;
const int MIC_WS = 25;
const int MIC_SD = 33;
const int GAIN_SHIFT = 16;
const int BUTTON_PIN = 0;
const int LED_PIN = 2;

const int STORED_RATE = 8000;
const int SLOT_SAMPLES = STORED_RATE;
const int MAX_SLOTS = 16;
const int SLOTS_PER_CHUNK = 5;
const uint32_t MEMORY_FOR_HTTPS = 80000;
const int SILENCE_LEVEL = 300;
const int SILENT_SECONDS_TO_END = 30;

const char *ANCS_SERVICE = "7905F431-B5CE-4E99-A40F-4B1E122D00D0";
const char *ANCS_NOTIFICATION_SOURCE = "9FBF120D-6301-42D9-8C58-25E699A21DBD";
const char *PUCK_SERVICE = "5B4F74AF-95E4-4449-8129-C97AD2293807";
const char *PUCK_PAIRING = "29308BE3-4FCA-47FB-AF2D-3539D416BAA1";
const char *PUCK_WIFI = "8E1F2A6C-3B7D-4C59-9A0E-5D2F7B4C1E93";
const uint8_t ANCS_EVENT_ADDED = 0;
const uint8_t ANCS_EVENT_REMOVED = 2;
const uint8_t ANCS_FLAG_PRE_EXISTING = 4;
const uint8_t ANCS_CATEGORY_INCOMING_CALL = 1;
const uint8_t ANCS_CATEGORY_MISSED_CALL = 2;
const uint8_t ANCS_CATEGORY_ACTIVE_CALL = 12;

struct Adpcm {
  int predicted = 0;
  int index = 0;
};

uint8_t *slots[MAX_SLOTS];
int slotCount = 0;
int slotsPerChunk;
volatile int slotFill[MAX_SLOTS];
volatile bool slotFinal[MAX_SLOTS];
QueueHandle_t freeSlots;
QueueHandle_t filledSlots;

I2SClass i2s;
volatile bool recording = false;
volatile bool stopRequested = false;

String serverHost;
String puckToken;
int serverPort;
bool useHttps;
volatile bool wifiChanged = false;
unsigned long wifiStartedAt = 0;
NimBLECharacteristic *wifiStatus;
String sessionId;
int nextSequence = 0;
bool listening = false;
bool stopping = false;
int pending[MAX_SLOTS];
int pendingCount = 0;
int silentSeconds = 0;
unsigned long lastPoll = 0;

NimBLEServer *bleServer;
volatile uint16_t iphoneHandle = BLE_HS_CONN_HANDLE_NONE;
volatile bool ancsPending = false;
volatile bool incomingCall = false;
volatile bool callEnded = false;

void saveWifi(String config) {
  String parts[6];
  for (int i = 0; i < 6; i++) {
    int end = config.indexOf('\n');
    parts[i] = end < 0 ? config : config.substring(0, end);
    config = end < 0 ? "" : config.substring(end + 1);
  }
  Preferences settings;
  settings.begin("puck");
  settings.putString("ssid", parts[0]);
  settings.putString("password", parts[1]);
  if (parts[2].length()) {
    settings.putString("host", parts[2]);
    settings.putInt("port", parts[3].toInt());
    settings.putBool("https", parts[4] == "1");
  }
  if (parts[5].length()) {
    settings.putString("token", parts[5]);
  }
  settings.end();
  wifiChanged = true;
}

class WifiSetup : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    saveWifi(characteristic->getValue().c_str());
  }
};

class PhoneLink : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &info) override {
    NimBLEDevice::startSecurity(info.getConnHandle());
  }

  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    if (!info.isEncrypted()) return;
    iphoneHandle = info.getConnHandle();
    ancsPending = true;
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    iphoneHandle = BLE_HS_CONN_HANDLE_NONE;
    Serial.println("iPhone Bluetooth disconnected");
    NimBLEDevice::startAdvertising();
  }
};

volatile uint16_t ancsSourceHandle = 0;
ble_gap_event_listener notificationListener;

// NimBLEServer does not pass notifications to a client made with getClient(), so catch them here.
int onGapEvent(ble_gap_event *event, void *) {
  if (event->type != BLE_GAP_EVENT_NOTIFY_RX || event->notify_rx.attr_handle != ancsSourceHandle) return 0;
  uint8_t data[8];
  if (OS_MBUF_PKTLEN(event->notify_rx.om) < 8 || os_mbuf_copydata(event->notify_rx.om, 0, 8, data) != 0) return 0;
  if (data[1] & ANCS_FLAG_PRE_EXISTING) return 0;
  if (data[0] == ANCS_EVENT_ADDED && data[2] == ANCS_CATEGORY_INCOMING_CALL) incomingCall = true;
  if (data[0] == ANCS_EVENT_REMOVED && data[2] == ANCS_CATEGORY_ACTIVE_CALL) callEnded = true;
  if (data[0] == ANCS_EVENT_ADDED && data[2] == ANCS_CATEGORY_MISSED_CALL) callEnded = true;
  return 0;
}

void subscribeToCallAlerts() {
  ancsPending = false;
  NimBLEClient *client = bleServer->getClient(iphoneHandle);
  NimBLERemoteService *ancs = client ? client->getService(ANCS_SERVICE) : nullptr;
  NimBLERemoteCharacteristic *source = ancs ? ancs->getCharacteristic(ANCS_NOTIFICATION_SOURCE) : nullptr;
  if (source && source->subscribe(true)) {
    ancsSourceHandle = source->getHandle();
    Serial.println("iPhone call alerts connected");
  }
  else Serial.println("Could not subscribe to iPhone call alerts");
}

void startBluetooth() {
  NimBLEDevice::init("Rambu Puck");
  ble_gap_event_listener_register(&notificationListener, onGapEvent, nullptr);
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new PhoneLink());
  NimBLEService *service = bleServer->createService(PUCK_SERVICE);
  NimBLECharacteristic *pairing =
      service->createCharacteristic(PUCK_PAIRING, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC);
  pairing->setValue("paired");
  wifiStatus = service->createCharacteristic(
      PUCK_WIFI, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC);
  wifiStatus->setValue("offline");
  wifiStatus->setCallbacks(new WifiSetup());
  service->start();
  bleServer->start();

  const uint8_t solicitAncs[18] = {17, 0x15, 0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4,
                                   0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79};
  NimBLEAdvertisementData advertisement;
  advertisement.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  advertisement.addData(solicitAncs, sizeof(solicitAncs));
  NimBLEAdvertisementData scanResponse;
  scanResponse.setName("Rambu Puck");
  scanResponse.addServiceUUID(PUCK_SERVICE);
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->setAdvertisementData(advertisement);
  advertising->setScanResponseData(scanResponse);
  advertising->start();
}

const int16_t ADPCM_STEPS[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60,
    66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371,
    408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878,
    2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
    8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086,
    29794, 32767};
const int8_t ADPCM_INDEX_SHIFT[8] = {-1, -1, -1, -1, 2, 4, 6, 8};

int16_t adpcmDecode(Adpcm &state, uint8_t code) {
  int step = ADPCM_STEPS[state.index];
  int delta = step >> 3;
  if (code & 4) delta += step;
  if (code & 2) delta += step >> 1;
  if (code & 1) delta += step >> 2;
  state.predicted = constrain(state.predicted + (code & 8 ? -delta : delta), -32768, 32767);
  state.index = constrain(state.index + ADPCM_INDEX_SHIFT[code & 7], 0, 88);
  return state.predicted;
}

uint8_t adpcmEncode(Adpcm &state, int sample) {
  int step = ADPCM_STEPS[state.index];
  int difference = sample - state.predicted;
  uint8_t code = 0;
  if (difference < 0) {
    code = 8;
    difference = -difference;
  }
  if (difference >= step) { code |= 4; difference -= step; }
  if (difference >= step >> 1) { code |= 2; difference -= step >> 1; }
  if (difference >= step >> 2) code |= 1;
  adpcmDecode(state, code);
  return code;
}

int16_t sampleAt(int slot, int index, Adpcm &state) {
  return adpcmDecode(state, (slots[slot][index / 2] >> ((index & 1) * 4)) & 0x0F);
}

void recorderTask(void *) {
  int slot = -1;
  Adpcm encoder;
  bool warned = false;
  int32_t raw[256];
  auto startSlot = [&](int next) {
    slot = next;
    slotFill[slot] = 0;
    slotFinal[slot] = false;
    encoder = Adpcm();
  };
  for (;;) {
    if (!recording) {
      if (stopRequested) {
        if (slot < 0) {
          int next;
          xQueueReceive(freeSlots, &next, portMAX_DELAY);
          startSlot(next);
        }
        slotFinal[slot] = true;
        xQueueSend(filledSlots, &slot, portMAX_DELAY);
        slot = -1;
        stopRequested = false;
      }
      i2s.readBytes((char *)raw, sizeof(raw));
      continue;
    }
    if (slot < 0) {
      int next;
      if (xQueueReceive(freeSlots, &next, 0) != pdTRUE) {
        if (!warned) Serial.println("Server too slow, dropping audio");
        warned = true;
        i2s.readBytes((char *)raw, sizeof(raw));
        continue;
      }
      warned = false;
      startSlot(next);
    }
    int got = i2s.readBytes((char *)raw, sizeof(raw)) / 4;
    for (int i = 0; i + 1 < got; i += 2) {
      int sample = constrain(((raw[i] >> GAIN_SHIFT) + (raw[i + 1] >> GAIN_SHIFT)) / 2, -32768, 32767);
      int n = slotFill[slot];
      uint8_t code = adpcmEncode(encoder, sample);
      slots[slot][n / 2] = n & 1 ? (slots[slot][n / 2] | code << 4) : code;
      slotFill[slot] = n + 1;
      if (slotFill[slot] == SLOT_SAMPLES) {
        xQueueSend(filledSlots, &slot, portMAX_DELAY);
        int next;
        if (xQueueReceive(freeSlots, &next, 0) != pdTRUE) {
          slot = -1;
          break;
        }
        startSlot(next);
      }
    }
  }
}

void put32(uint8_t *p, uint32_t v) {
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

void put16(uint8_t *p, uint16_t v) {
  p[0] = v; p[1] = v >> 8;
}

void writeWav(Client &client, int *chunkSlots, int count) {
  uint32_t dataBytes = 0;
  for (int i = 0; i < count; i++) dataBytes += slotFill[chunkSlots[i]] * 4;
  uint8_t h[44];
  memcpy(h, "RIFF", 4); put32(h + 4, 36 + dataBytes);
  memcpy(h + 8, "WAVEfmt ", 8); put32(h + 16, 16);
  put16(h + 20, 1); put16(h + 22, 1);
  put32(h + 24, 16000); put32(h + 28, 32000);
  put16(h + 32, 2); put16(h + 34, 16);
  memcpy(h + 36, "data", 4); put32(h + 40, dataBytes);
  client.write(h, 44);

  int16_t out[512];
  int n = 0;
  int16_t previous = 0;
  for (int i = 0; i < count; i++) {
    int slot = chunkSlots[i];
    Adpcm decoder;
    for (int s = 0; s < slotFill[slot]; s++) {
      int16_t current = sampleAt(slot, s, decoder);
      out[n++] = (previous + current) / 2;
      out[n++] = current;
      previous = current;
      if (n == 512) {
        client.write((uint8_t *)out, sizeof(out));
        n = 0;
      }
    }
  }
  if (n) client.write((uint8_t *)out, n * 2);
}

WiFiClientSecure secureClient;
WiFiClient plainClient;

int httpRequest(const char *method, String path, String extraHeaders, uint32_t bodyLength,
                std::function<void(Client &)> writeBody, JsonDocument &reply) {
  for (int attempt = 0; attempt < 3; attempt++) {
    Client &client = useHttps ? (Client &)secureClient : (Client &)plainClient;
    if (!client.connected() && !client.connect(serverHost.c_str(), serverPort)) {
      char reason[100] = "";
      if (useHttps) secureClient.lastError(reason, sizeof(reason));
      Serial.printf("Cannot reach server (%s), free memory %u / largest %u, retrying\n", reason, ESP.getFreeHeap(), ESP.getMaxAllocHeap());
      delay(attempt == 0 ? 250 : 750);
      continue;
    }
    client.print(String(method) + " " + path + " HTTP/1.1\r\n" +
                 "Host: " + serverHost + "\r\n" +
                 "Authorization: Bearer " + puckToken + "\r\n" +
                 "Connection: keep-alive\r\n" +
                 "Content-Length: " + bodyLength + "\r\n" +
                 extraHeaders + "\r\n");
    if (writeBody) writeBody(client);

    unsigned long deadline = millis() + 60000;
    while (!client.available() && client.connected() && millis() < deadline) delay(10);
    String statusLine = client.readStringUntil('\n');
    int status = statusLine.substring(9, 12).toInt();
    int contentLength = -1;
    for (;;) {
      String line = client.readStringUntil('\n');
      line.trim();
      if (line.isEmpty()) break;
      line.toLowerCase();
      if (line.startsWith("content-length:")) contentLength = line.substring(15).toInt();
    }
    String body;
    while ((contentLength < 0 || (int)body.length() < contentLength) && millis() < deadline) {
      if (client.available()) body += (char)client.read();
      else if (!client.connected()) break;
      else delay(1);
    }
    if (contentLength < 0 || (int)body.length() < contentLength) client.stop();

    if (status == 0) {
      client.stop();
      continue;
    }
    if (status >= 500) {
      Serial.printf("Server error %d, retrying\n", status);
      delay(attempt == 0 ? 250 : 750);
      continue;
    }
    if (status >= 200 && status < 300) deserializeJson(reply, body);
    else if (status != 404) Serial.printf("HTTP %d: %s\n", status, body.c_str());
    return status;
  }
  return -1;
}

void beginListening(JsonDocument &session) {
  sessionId = session["id"].as<String>();
  nextSequence = session["next_sequence"];
  pendingCount = 0;
  silentSeconds = 0;
  listening = true;
  stopping = false;
  recording = true;
  digitalWrite(LED_PIN, HIGH);
  Serial.printf("RECORDING session %s\n", sessionId.c_str());
}

void requestStop() {
  if (stopping) return;
  stopping = true;
  recording = false;
  stopRequested = true;
  Serial.println("Ending session...");
}

bool fetchActiveSession(JsonDocument &session) {
  return httpRequest("GET", "/api/pucks/sessions/active", "", 0, nullptr, session) == 200;
}

String uuid4() {
  uint8_t b[16];
  esp_fill_random(b, 16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  char s[37];
  snprintf(s, sizeof(s), "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
  return s;
}

void startSession(const char *channel, const char *title, const char *callerDetail) {
  JsonDocument session;
  if (fetchActiveSession(session)) {
    beginListening(session);
    return;
  }
  time_t now = time(nullptr);
  char startedAt[25];
  strftime(startedAt, sizeof(startedAt), "%Y-%m-%dT%H:%M:%SZ", gmtime(&now));
  JsonDocument request;
  request["call_id"] = uuid4();
  request["started_at"] = startedAt;
  request["channel"] = channel;
  request["title"] = title;
  request["caller_detail"] = callerDetail;
  String json;
  serializeJson(request, json);
  int status = httpRequest("POST", "/api/pucks/sessions", "Content-Type: application/json\r\n",
                           json.length(), [&](Client &c) { c.print(json); }, session);
  if (status == 201) beginListening(session);
  else if (status == 409 && fetchActiveSession(session)) beginListening(session);
}

void finishSession() {
  listening = false;
  digitalWrite(LED_PIN, LOW);
  Serial.println("Session completed. Waiting for the next call.");
}

void uploadPending(bool final) {
  uint32_t samples = 0;
  for (int i = 0; i < pendingCount; i++) samples += slotFill[pending[i]];
  String headers = String("Content-Type: audio/wav\r\n") +
                   "X-Rambu-Sequence: " + nextSequence + "\r\n" +
                   "X-Rambu-Final: " + (final ? "true" : "false") + "\r\n";
  JsonDocument session;
  int status = httpRequest("POST", "/api/pucks/sessions/" + sessionId + "/chunks", headers,
                           44 + samples * 4, [](Client &c) { writeWav(c, pending, pendingCount); }, session);
  for (int i = 0; i < pendingCount; i++) xQueueSend(freeSlots, &pending[i], 0);
  pendingCount = 0;

  if (status != 200) {
    Serial.println("Upload failed");
    if (final) finishSession(); else requestStop();
    return;
  }
  Serial.printf("Chunk %d heard: %s\n", nextSequence, session["masked_transcript"].as<const char *>());
  if (!session["assessment"].isNull()) {
    Serial.printf("Risk: %s\n", session["assessment"]["risk_level"].as<const char *>());
  }
  nextSequence++;
  if (final) finishSession();
  else if (session["end_requested"] == true) requestStop();
}

bool isSilent(int slot) {
  double sum = 0;
  Adpcm decoder;
  for (int i = 0; i < slotFill[slot]; i++) {
    double sample = sampleAt(slot, i, decoder);
    sum += sample * sample;
  }
  return slotFill[slot] == 0 || sqrt(sum / slotFill[slot]) < SILENCE_LEVEL;
}

void connectWifi() {
  Preferences settings;
  settings.begin("puck", true);
  String ssid = settings.getString("ssid", "");
  String password = settings.getString("password", "");
  serverHost = settings.getString("host", "");
  serverPort = settings.getInt("port", 443);
  useHttps = settings.getBool("https", true);
  puckToken = settings.getString("token", "");
  settings.end();

  secureClient.stop();
  plainClient.stop();
  WiFi.disconnect();
  if (ssid.isEmpty() || serverHost.isEmpty() || puckToken.isEmpty()) {
    Serial.println("Not set up yet. Pair it from the Rambu app, Puck tab.");
    wifiStartedAt = 0;
    return;
  }
  Serial.printf("Connecting to Wi-Fi %s\n", ssid.c_str());
  wifiStatus->setValue("connecting");
  wifiStatus->notify();
  WiFi.begin(ssid.c_str(), password.c_str());
  wifiStartedAt = millis();
}

void reportWifi() {
  if (!wifiStartedAt) return;
  if (WiFi.status() == WL_CONNECTED) {
    wifiStartedAt = 0;
    Serial.printf("Wi-Fi connected: %s, server %s:%d\n", WiFi.localIP().toString().c_str(), serverHost.c_str(), serverPort);
    configTime(0, 0, "pool.ntp.org");
    wifiStatus->setValue("connected");
    wifiStatus->notify();
  } else if (millis() - wifiStartedAt > 20000) {
    wifiStartedAt = 0;
    Serial.println("Wi-Fi failed. Check the name and password in the Rambu app.");
    wifiStatus->setValue("failed");
    wifiStatus->notify();
  }
}

bool buttonPressed() {
  static int last = HIGH;
  int now = digitalRead(BUTTON_PIN);
  bool pressed = last == HIGH && now == LOW;
  last = now;
  if (pressed) delay(50);
  return pressed;
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  WiFi.setMinSecurity(WIFI_AUTH_WPA_PSK);
  secureClient.setInsecure();
  esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
  startBluetooth();
  connectWifi();

  freeSlots = xQueueCreate(MAX_SLOTS, sizeof(int));
  filledSlots = xQueueCreate(MAX_SLOTS, sizeof(int));
  for (int i = 0; i < MAX_SLOTS && ESP.getFreeHeap() > MEMORY_FOR_HTTPS + SLOT_SAMPLES / 2; i++) {
    slots[i] = (uint8_t *)malloc(SLOT_SAMPLES / 2);
    if (!slots[i]) break;
    slotCount++;
    xQueueSend(freeSlots, &i, 0);
  }
  slotsPerChunk = min(SLOTS_PER_CHUNK, max(1, slotCount - 3));
  Serial.printf("Audio buffer: %d seconds, free memory %u / largest %u\n", slotCount, ESP.getFreeHeap(), ESP.getMaxAllocHeap());

  i2s.setPins(MIC_SCK, MIC_WS, -1, MIC_SD);
  if (!i2s.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO, I2S_STD_SLOT_LEFT)) {
    Serial.println("Microphone failed to start. Check the wiring.");
    for (;;) delay(1000);
  }

  xTaskCreatePinnedToCore(recorderTask, "recorder", 8192, nullptr, 2, nullptr, 0);
  Serial.println("Ready. Waiting for a call, or press BOOT to start manually.");
}

void loop() {
  if (ancsPending && iphoneHandle != BLE_HS_CONN_HANDLE_NONE) subscribeToCallAlerts();
  if (wifiChanged) {
    wifiChanged = false;
    connectWifi();
  }
  reportWifi();
  if (WiFi.status() != WL_CONNECTED) return;

  if (incomingCall) {
    incomingCall = false;
    if (!listening) {
      Serial.println("Incoming call detected");
      startSession("cellular", "Panggilan masuk terdeteksi", "Terdeteksi oleh puck");
    }
  }

  if (callEnded) {
    callEnded = false;
    if (listening) {
      Serial.println("Call ended");
      requestStop();
    }
  }

  if (buttonPressed()) {
    if (!listening) startSession("whatsapp", "Panggilan WhatsApp terdeteksi", "Kontak WhatsApp");
    else requestStop();
  }

  if (!listening) {
    if (millis() - lastPoll > 1000) {
      lastPoll = millis();
      JsonDocument session;
      if (fetchActiveSession(session)) beginListening(session);
    }
    return;
  }

  int slot;
  if (xQueueReceive(filledSlots, &slot, pdMS_TO_TICKS(100)) != pdTRUE) return;
  pending[pendingCount++] = slot;
  silentSeconds = isSilent(slot) ? silentSeconds + 1 : 0;
  if (silentSeconds == SILENT_SECONDS_TO_END) {
    Serial.println("No call audio for 30 seconds");
    requestStop();
  }
  if (slotFinal[slot]) uploadPending(true);
  else if (pendingCount == slotsPerChunk) uploadPending(false);
}
