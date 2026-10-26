#pragma once

#include <cstddef>
#include <cstdint>

template <std::size_t SlotCount, std::size_t SamplesPerSlot>
class StaticAudioSlots {
 public:
  static constexpr std::size_t count() { return SlotCount; }
  static constexpr std::size_t bytesPerSlot() { return SamplesPerSlot / 2; }

  uint8_t *operator[](std::size_t index) { return data_[index]; }
  const uint8_t *operator[](std::size_t index) const { return data_[index]; }

 private:
  uint8_t data_[SlotCount][SamplesPerSlot / 2] = {};
};
