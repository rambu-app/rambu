#include <WiFi.h>
#include <Preferences.h>
#include <WiFiClientSecure.h>
#include <ESP_I2S.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <time.h>
#include <esp_bt.h>
#include "call_alert_subscription.h"
#include "http_retry_policy.h"
#include "puck_network_protocol.h"
#include "puck_runtime_state.h"
#include "static_audio_slots.h"
#include "wifi_failover_policy.h"
#include "wifi_retry_policy.h"

const int MIC_SCK = 32;
const int MIC_WS = 25;
const int MIC_SD = 33;
const int GAIN_SHIFT = 16;
const int BUTTON_PIN = 0;
const int LED_PIN = 2;

const int STORED_RATE = 8000;
const int SLOT_SAMPLES = STORED_RATE;
const int MAX_SLOTS = 8;
const int SLOTS_PER_CHUNK = 5;
const uint32_t HTTP_CONNECT_TIMEOUT_MS = 5000;
const uint32_t HTTP_RESPONSE_TIMEOUT_MS = 8000;
const uint32_t HTTPS_HANDSHAKE_TIMEOUT_SECONDS = 15;
const uint32_t WIFI_CONNECT_TIMEOUT_MS = 20000;
const uint32_t PRIMARY_RETRY_INTERVAL_MS = 300000;
const uint32_t RECORDER_TASK_STACK_BYTES = 8192;
const uint32_t BUTTON_TASK_STACK_BYTES = 2048;
const int SILENCE_LEVEL = 300;
const int SILENT_SECONDS_TO_END = 30;

const char *ANCS_SERVICE = "7905F431-B5CE-4E99-A40F-4B1E122D00D0";
const char *ANCS_NOTIFICATION_SOURCE = "9FBF120D-6301-42D9-8C58-25E699A21DBD";
const char *PUCK_SERVICE = "5B4F74AF-95E4-4449-8129-C97AD2293807";
const char *PUCK_PAIRING = "29308BE3-4FCA-47FB-AF2D-3539D416BAA1";
const char *PUCK_WIFI = "8E1F2A6C-3B7D-4C59-9A0E-5D2F7B4C1E93";
const char *PUCK_NETWORK_PROVISIONING = "6B5A3C8D-6E28-4DAA-82B5-2AE6C52C9174";
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

StaticAudioSlots<MAX_SLOTS, SLOT_SAMPLES> slots;
const int slotCount = MAX_SLOTS;
int slotsPerChunk;
volatile int slotFill[MAX_SLOTS];
volatile bool slotFinal[MAX_SLOTS];
QueueHandle_t freeSlots;
QueueHandle_t filledSlots;
StaticQueue_t freeSlotsQueueBuffer;
StaticQueue_t filledSlotsQueueBuffer;
uint8_t freeSlotsQueueStorage[MAX_SLOTS * sizeof(int)];
uint8_t filledSlotsQueueStorage[MAX_SLOTS * sizeof(int)];
StaticTask_t recorderTaskBuffer;
StaticTask_t buttonTaskBuffer;
StackType_t recorderTaskStack[RECORDER_TASK_STACK_BYTES];
StackType_t buttonTaskStack[BUTTON_TASK_STACK_BYTES];

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
NimBLECharacteristic *networkProvisioning;
String primarySsid;
String primaryPassword;
String backupSsid;
String backupPassword;
WifiNetwork connectingNetwork = WifiNetwork::Primary;
WifiNetwork connectedNetwork = WifiNetwork::Primary;
unsigned long networkConnectedAt = 0;
bool wifiOnline = false;
volatile bool scanRequested = false;
bool scanRunning = false;
volatile bool backupConfigPending = false;
char pendingBackupSsid[33] = {};
char pendingBackupPassword[64] = {};
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
volatile uint16_t ancsSourceHandle = 0;
CallAlertSubscription callAlertSubscription;
volatile bool incomingCall = false;
volatile bool callEnded = false;
PuckRuntimeState runtimeState;

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

class NetworkProvisioning : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    const std::string value = characteristic->getValue();
    if (value.size() == 1 &&
        static_cast<uint8_t>(value[0]) == static_cast<uint8_t>(puck_network::Message::ScanRequest)) {
      scanRequested = true;
      return;
    }

    const auto credentials = puck_network::parseBackupCredentials(
        reinterpret_cast<const uint8_t *>(value.data()), value.size());
    if (!credentials.valid) {
      const uint8_t response[] = {
          static_cast<uint8_t>(puck_network::Message::Error),
          'I', 'n', 'v', 'a', 'l', 'i', 'd'};
      characteristic->setValue(response, sizeof(response));
      characteristic->notify();
      return;
    }

    memcpy(pendingBackupSsid, credentials.ssid, credentials.ssidLength);
    pendingBackupSsid[credentials.ssidLength] = '\0';
    memcpy(pendingBackupPassword, credentials.password, credentials.passwordLength);
    pendingBackupPassword[credentials.passwordLength] = '\0';
    backupConfigPending = true;
  }
};

class PhoneLink : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &info) override {
    NimBLEDevice::startSecurity(info.getConnHandle());
  }

  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    if (!info.isEncrypted()) return;
    iphoneHandle = info.getConnHandle();
    callAlertSubscription.authenticated();
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    iphoneHandle = BLE_HS_CONN_HANDLE_NONE;
    ancsSourceHandle = 0;
    callAlertSubscription.disconnected();
    Serial.println("iPhone Bluetooth disconnected");
    NimBLEDevice::startAdvertising();
  }
};

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
  networkProvisioning = service->createCharacteristic(
      PUCK_NETWORK_PROVISIONING,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::NOTIFY |
          NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC);
  networkProvisioning->setCallbacks(new NetworkProvisioning());
  const uint8_t idle = static_cast<uint8_t>(puck_network::Message::ScanFinished);
  networkProvisioning->setValue(&idle, 1);
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

void prepareSecureClient() {
  secureClient.stop();
  secureClient.setInsecure();
  secureClient.setHandshakeTimeout(HTTPS_HANDSHAKE_TIMEOUT_SECONDS);
  secureClient.setTimeout(HTTP_RESPONSE_TIMEOUT_MS);
}

void discardHttpClient() {
  if (useHttps) secureClient.stop();
  else plainClient.stop();
}

bool readHttpLine(Client &client, String &line, unsigned long startedAt) {
  line = "";
  while (millis() - startedAt < HTTP_RESPONSE_TIMEOUT_MS) {
    if (client.available()) {
      char value = (char)client.read();
      if (value == '\n') return true;
      if (value != '\r') line += value;
    } else if (!client.connected()) {
      return false;
    } else {
      delay(1);
    }
  }
  return false;
}

int httpRequest(const char *method, String path, String extraHeaders, uint32_t bodyLength,
                std::function<void(Client &)> writeBody, JsonDocument &reply) {
  for (int attempt = 0; attempt < 3; attempt++) {
    Client &client = useHttps ? (Client &)secureClient : (Client &)plainClient;
    client.setTimeout(HTTP_RESPONSE_TIMEOUT_MS);
    bool connected = client.connected();
    if (!connected) {
      connected = useHttps
                      ? secureClient.connect(serverHost.c_str(), serverPort, HTTP_CONNECT_TIMEOUT_MS)
                      : plainClient.connect(serverHost.c_str(), serverPort, HTTP_CONNECT_TIMEOUT_MS);
    }
    if (!connected) {
      char reason[100] = "";
      if (useHttps) secureClient.lastError(reason, sizeof(reason));
      Serial.printf("Cannot reach server (%s), free memory %u / largest %u, retrying\n", reason, ESP.getFreeHeap(), ESP.getMaxAllocHeap());
      discardHttpClient();
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

    unsigned long responseStartedAt = millis();
    String statusLine;
    bool statusLineComplete = readHttpLine(client, statusLine, responseStartedAt);
    int status = statusLineComplete ? statusLine.substring(9, 12).toInt() : 0;
    int contentLength = -1;
    bool headersComplete = false;
    while (statusLineComplete && millis() - responseStartedAt < HTTP_RESPONSE_TIMEOUT_MS) {
      String line;
      if (!readHttpLine(client, line, responseStartedAt)) break;
      line.trim();
      if (line.isEmpty()) {
        headersComplete = true;
        break;
      }
      line.toLowerCase();
      if (line.startsWith("content-length:")) contentLength = line.substring(15).toInt();
    }
    String body;
    if (contentLength > 0) body.reserve(contentLength);
    while (contentLength >= 0 && (int)body.length() < contentLength &&
           millis() - responseStartedAt < HTTP_RESPONSE_TIMEOUT_MS) {
      if (client.available()) body += (char)client.read();
      else if (!client.connected()) break;
      else delay(1);
    }
    bool responseComplete = statusLineComplete && headersComplete && contentLength >= 0 &&
                            (int)body.length() == contentLength;
    HttpAttemptDecision decision = decideHttpAttempt(status, responseComplete);
    if (decision.resetClient) discardHttpClient();
    if (decision.retry) {
      if (status >= 500) Serial.printf("Server error %d, retrying\n", status);
      else Serial.println("Incomplete server response, retrying");
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
  runtimeState.setListening(true);
  digitalWrite(LED_PIN, HIGH);
  Serial.printf("RECORDING session %s\n", sessionId.c_str());
}

void requestStop() {
  if (stopping) return;
  stopping = true;
  recording = false;
  stopRequested = true;
  digitalWrite(LED_PIN, LOW);
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
  runtimeState.setListening(false);
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

void loadNetworkSettings() {
  Preferences settings;
  settings.begin("puck", true);
  primarySsid = settings.getString("ssid", "");
  primaryPassword = settings.getString("password", "");
  backupSsid = settings.getString("bssid", "");
  backupPassword = settings.getString("bpass", "");
  serverHost = settings.getString("host", "");
  serverPort = settings.getInt("port", 443);
  useHttps = settings.getBool("https", true);
  puckToken = settings.getString("token", "");
  settings.end();
}

void connectWifi(WifiNetwork network = WifiNetwork::Primary) {
  prepareSecureClient();
  plainClient.stop();
  WiFi.disconnect(false, false, 1000);
  delay(100);
  const String &ssid = network == WifiNetwork::Primary ? primarySsid : backupSsid;
  const String &password = network == WifiNetwork::Primary ? primaryPassword : backupPassword;
  if (ssid.isEmpty() || serverHost.isEmpty() || puckToken.isEmpty()) {
    Serial.println("Not set up yet. Pair it from the Rambu app, Puck tab.");
    wifiStartedAt = 0;
    wifiOnline = false;
    return;
  }
  connectingNetwork = network;
  wifiOnline = false;
  Serial.printf("Connecting to Wi-Fi %s\n", ssid.c_str());
  wifiStatus->setValue("connecting");
  wifiStatus->notify();
  WiFi.begin(ssid.c_str(), password.c_str());
  wifiStartedAt = max(1UL, millis());
}

void reportWifi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (wifiOnline) {
      if (shouldProbePrimary(
              connectedNetwork, listening, networkConnectedAt, millis(),
              PRIMARY_RETRY_INTERVAL_MS)) {
        Serial.println("Checking whether primary Wi-Fi is available again...");
        connectWifi(WifiNetwork::Primary);
      }
      return;
    }
    wifiStartedAt = 0;
    wifiOnline = true;
    connectedNetwork = connectingNetwork;
    networkConnectedAt = millis();
    Serial.printf("Wi-Fi connected: %s, server %s:%d\n", WiFi.localIP().toString().c_str(), serverHost.c_str(), serverPort);
    configTime(0, 0, "pool.ntp.org");
    wifiStatus->setValue(
        connectedNetwork == WifiNetwork::Backup ? "backup_connected" : "connected");
    wifiStatus->notify();
  } else if (wifiOnline) {
    wifiOnline = false;
    connectWifi(nextNetworkAfterTimeout(connectedNetwork, !backupSsid.isEmpty()));
  } else if (shouldRetryWifi(wifiStartedAt, millis(), WIFI_CONNECT_TIMEOUT_MS)) {
    Serial.println("Wi-Fi connection timed out. Retrying...");
    wifiStatus->setValue("offline");
    wifiStatus->notify();
    connectWifi(nextNetworkAfterTimeout(connectingNetwork, !backupSsid.isEmpty()));
  }
}

void notifyProvisioning(puck_network::Message message, const String &payload = "") {
  std::string response;
  response.reserve(payload.length() + 1);
  response.push_back(static_cast<char>(message));
  response.append(payload.c_str(), payload.length());
  networkProvisioning->setValue(
      reinterpret_cast<const uint8_t *>(response.data()), response.size());
  networkProvisioning->notify();
}

void handleNetworkProvisioning() {
  if (backupConfigPending) {
    backupConfigPending = false;
    Preferences settings;
    settings.begin("puck");
    settings.putString("bssid", pendingBackupSsid);
    settings.putString("bpass", pendingBackupPassword);
    settings.end();
    backupSsid = pendingBackupSsid;
    backupPassword = pendingBackupPassword;
    memset(pendingBackupPassword, 0, sizeof(pendingBackupPassword));
    notifyProvisioning(puck_network::Message::BackupSaved);
    if (WiFi.status() != WL_CONNECTED) connectWifi(WifiNetwork::Backup);
  }

  if (scanRequested && !scanRunning) {
    scanRequested = false;
    WiFi.scanDelete();
    notifyProvisioning(puck_network::Message::ScanStarted);
    scanRunning = WiFi.scanNetworks(true, false, false, 120) == WIFI_SCAN_RUNNING;
    if (!scanRunning) notifyProvisioning(puck_network::Message::Error, "Scan failed");
  }

  if (!scanRunning) return;
  int count = WiFi.scanComplete();
  if (count == WIFI_SCAN_RUNNING) return;
  if (count < 0) {
    notifyProvisioning(puck_network::Message::Error, "Scan failed");
  } else {
    for (int i = 0; i < count; i++) {
      String ssid = WiFi.SSID(i);
      if (!ssid.isEmpty()) notifyProvisioning(puck_network::Message::Network, ssid);
    }
    notifyProvisioning(puck_network::Message::ScanFinished);
  }
  WiFi.scanDelete();
  scanRunning = false;
}

void buttonTask(void *) {
  int last = digitalRead(BUTTON_PIN);
  for (;;) {
    int now = digitalRead(BUTTON_PIN);
    if (last == HIGH && now == LOW) {
      ManualAction action = runtimeState.pressButton();
      if (action == ManualAction::Stop) {
        recording = false;
        stopRequested = true;
        digitalWrite(LED_PIN, LOW);
        Serial.println("BOOT stop requested");
      } else {
        Serial.println("BOOT start requested");
      }
      vTaskDelay(pdMS_TO_TICKS(50));
    }
    last = now;
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  WiFi.setMinSecurity(WIFI_AUTH_WPA_PSK);
  WiFi.setAutoReconnect(false);
  esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
  startBluetooth();
  loadNetworkSettings();
  connectWifi();

  freeSlots = xQueueCreateStatic(
      MAX_SLOTS, sizeof(int), freeSlotsQueueStorage, &freeSlotsQueueBuffer);
  filledSlots = xQueueCreateStatic(
      MAX_SLOTS, sizeof(int), filledSlotsQueueStorage, &filledSlotsQueueBuffer);
  for (int i = 0; i < slotCount; i++) xQueueSend(freeSlots, &i, 0);
  slotsPerChunk = min(SLOTS_PER_CHUNK, max(1, slotCount - 3));
  Serial.printf("Audio buffer: %d seconds, free memory %u / largest %u\n", slotCount, ESP.getFreeHeap(), ESP.getMaxAllocHeap());

  i2s.setPins(MIC_SCK, MIC_WS, -1, MIC_SD);
  if (!i2s.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO, I2S_STD_SLOT_LEFT)) {
    Serial.println("Microphone failed to start. Check the wiring.");
    for (;;) delay(1000);
  }

  xTaskCreateStaticPinnedToCore(
      recorderTask, "recorder", RECORDER_TASK_STACK_BYTES, nullptr, 2,
      recorderTaskStack, &recorderTaskBuffer, 0);
  xTaskCreateStaticPinnedToCore(
      buttonTask, "button", BUTTON_TASK_STACK_BYTES, nullptr, 3,
      buttonTaskStack, &buttonTaskBuffer, 1);
  Serial.println("Ready. Waiting for a call, or press BOOT to start manually.");
}

void loop() {
  if (iphoneHandle != BLE_HS_CONN_HANDLE_NONE && callAlertSubscription.takePendingAttempt()) {
    subscribeToCallAlerts();
  }
  if (wifiChanged) {
    wifiChanged = false;
    loadNetworkSettings();
    connectWifi();
  }
  handleNetworkProvisioning();
  reportWifi();
  if (WiFi.status() != WL_CONNECTED) return;

  ManualAction manualAction = runtimeState.takePendingAction();
  if (manualAction == ManualAction::Start && !listening) {
    startSession("whatsapp", "Panggilan WhatsApp terdeteksi", "Kontak WhatsApp");
  } else if (manualAction == ManualAction::Stop && listening) {
    requestStop();
  }

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
