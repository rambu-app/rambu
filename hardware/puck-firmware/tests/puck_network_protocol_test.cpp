#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

#include "../puck_network_protocol.h"

static std::string text(const uint8_t *bytes, std::size_t size) {
  return std::string(reinterpret_cast<const char *>(bytes), size);
}

int main() {
  using namespace puck_network;

  assert(static_cast<uint8_t>(Message::ScanRequest) == 0x01);
  assert(static_cast<uint8_t>(Message::ScanStarted) == 0x01);
  assert(static_cast<uint8_t>(Message::Network) == 0x02);
  assert(static_cast<uint8_t>(Message::ScanFinished) == 0x03);
  assert(static_cast<uint8_t>(Message::SaveBackup) == 0x04);
  assert(static_cast<uint8_t>(Message::BackupSaved) == 0x04);
  assert(static_cast<uint8_t>(Message::Error) == 0x05);

  const std::vector<uint8_t> valid = {
      0x04, 0x0e, 'Z', 'a', 'h', 'r', 'a', '\'', 's', ' ', 'i', 'P', 'h', 'o', 'n', 'e',
      's', 'a', 'f', 'e', '-', 'p', 'a', 's', 's'};
  const BackupCredentials parsed = parseBackupCredentials(valid.data(), valid.size());
  assert(parsed.valid);
  assert(text(parsed.ssid, parsed.ssidLength) == "Zahra's iPhone");
  assert(text(parsed.password, parsed.passwordLength) == "safe-pass");

  const std::vector<uint8_t> truncated = {0x04, 0x05, 'R', 'a'};
  assert(!parseBackupCredentials(truncated.data(), truncated.size()).valid);

  const std::vector<uint8_t> emptySsid = {0x04, 0x00, 'p', 'a', 's', 's'};
  assert(!parseBackupCredentials(emptySsid.data(), emptySsid.size()).valid);

  std::vector<uint8_t> oversizedSsid = {0x04, 33};
  oversizedSsid.insert(oversizedSsid.end(), 33, 'a');
  oversizedSsid.insert(oversizedSsid.end(), 8, 'p');
  assert(!parseBackupCredentials(oversizedSsid.data(), oversizedSsid.size()).valid);

  std::vector<uint8_t> oversizedPassword = {0x04, 4, 't', 'e', 's', 't'};
  oversizedPassword.insert(oversizedPassword.end(), 64, 'p');
  assert(!parseBackupCredentials(oversizedPassword.data(), oversizedPassword.size()).valid);

  const std::vector<uint8_t> wrongType = {0x01, 0x01, 'x', 'p', 'a', 's', 's', 'w', 'o', 'r', 'd'};
  assert(!parseBackupCredentials(wrongType.data(), wrongType.size()).valid);
}
