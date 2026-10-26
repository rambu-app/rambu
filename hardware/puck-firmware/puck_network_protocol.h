#pragma once

#include <cstddef>
#include <cstdint>

namespace puck_network {

enum class Message : uint8_t {
  ScanRequest = 0x01,
  ScanStarted = 0x01,
  Network = 0x02,
  ScanFinished = 0x03,
  SaveBackup = 0x04,
  BackupSaved = 0x04,
  Error = 0x05,
};

struct BackupCredentials {
  bool valid = false;
  const uint8_t *ssid = nullptr;
  std::size_t ssidLength = 0;
  const uint8_t *password = nullptr;
  std::size_t passwordLength = 0;
};

inline BackupCredentials parseBackupCredentials(const uint8_t *data, std::size_t size) {
  BackupCredentials result;
  if (!data || size < 2 || data[0] != static_cast<uint8_t>(Message::SaveBackup)) return result;

  const std::size_t ssidLength = data[1];
  if (ssidLength == 0 || ssidLength > 32 || size < 2 + ssidLength) return result;

  const std::size_t passwordLength = size - 2 - ssidLength;
  if (passwordLength < 8 || passwordLength > 63) return result;

  result.valid = true;
  result.ssid = data + 2;
  result.ssidLength = ssidLength;
  result.password = data + 2 + ssidLength;
  result.passwordLength = passwordLength;
  return result;
}

}  // namespace puck_network
