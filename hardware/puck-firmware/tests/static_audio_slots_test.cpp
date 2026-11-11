#include <cassert>
#include <cstddef>

#include "../static_audio_slots.h"

int main() {
  StaticAudioSlots<8, 8000> slots;

  static_assert(slots.count() == 8);
  static_assert(slots.bytesPerSlot() == 4000);

  for (std::size_t i = 0; i + 1 < slots.count(); ++i) {
    assert(slots[i + 1] - slots[i] == 4000);
  }

  slots[0][3999] = 42;
  assert(slots[0][3999] == 42);
  assert(slots[1][0] == 0);
}
