#pragma once

#include <atomic>
#include <cstdint>

class CallAlertSubscription {
 public:
  void authenticated() {
    uint8_t expected = IDLE;
    state_.compare_exchange_strong(
        expected,
        ATTEMPTED | PENDING,
        std::memory_order_release,
        std::memory_order_relaxed);
  }

  bool takePendingAttempt() {
    return (state_.fetch_and(ATTEMPTED, std::memory_order_acq_rel) & PENDING) != 0;
  }

  void disconnected() {
    state_.store(IDLE, std::memory_order_release);
  }

 private:
  static constexpr uint8_t IDLE = 0;
  static constexpr uint8_t ATTEMPTED = 1 << 0;
  static constexpr uint8_t PENDING = 1 << 1;

  std::atomic<uint8_t> state_{IDLE};
};
