#pragma once

#include <cstdint>

enum class WifiNetwork {
  Primary,
  Backup,
};

inline WifiNetwork nextNetworkAfterTimeout(WifiNetwork current, bool backupAvailable) {
  if (current == WifiNetwork::Primary) {
    return backupAvailable ? WifiNetwork::Backup : WifiNetwork::Primary;
  }
  return WifiNetwork::Primary;
}

inline bool shouldProbePrimary(
    WifiNetwork current,
    bool listening,
    uint32_t connectedAt,
    uint32_t now,
    uint32_t interval) {
  return current == WifiNetwork::Backup && !listening &&
         static_cast<uint32_t>(now - connectedAt) >= interval;
}
