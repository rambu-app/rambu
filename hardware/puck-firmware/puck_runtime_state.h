#pragma once

#include <atomic>
#include <cstdint>

enum class ManualAction : uint8_t {
  None = 0,
  Start,
  Stop,
};

class PuckRuntimeState {
 public:
  void setListening(bool listening) {
    listening_.store(listening, std::memory_order_release);
  }

  ManualAction pressButton() {
    ManualAction action = listening_.load(std::memory_order_acquire)
                              ? ManualAction::Stop
                              : ManualAction::Start;
    pendingAction_.store(static_cast<uint8_t>(action), std::memory_order_release);
    return action;
  }

  ManualAction takePendingAction() {
    return static_cast<ManualAction>(
        pendingAction_.exchange(static_cast<uint8_t>(ManualAction::None),
                                std::memory_order_acq_rel));
  }

 private:
  std::atomic<bool> listening_{false};
  std::atomic<uint8_t> pendingAction_{static_cast<uint8_t>(ManualAction::None)};
};
