#pragma once

#include <cstdint>

inline bool shouldRetryWifi(uint32_t startedAt, uint32_t now, uint32_t timeout) {
  return startedAt != 0 && now - startedAt > timeout;
}
