#pragma once

enum class PuckStreamPhase {
  Idle,
  Connecting,
  Ready,
  Finishing,
  Complete,
  Failed,
};

enum class PuckStreamFailureAction {
  UseBatchFallback,
  StopSession,
};

class PuckStreamState {
 public:
  PuckStreamPhase phase() const { return phase_; }

  bool canSendAudio() const { return phase_ == PuckStreamPhase::Ready; }

  void begin() {
    phase_ = PuckStreamPhase::Connecting;
    wasReady_ = false;
  }

  void ready() {
    if (phase_ != PuckStreamPhase::Connecting) return;
    phase_ = PuckStreamPhase::Ready;
    wasReady_ = true;
  }

  void beginFinish() {
    if (phase_ == PuckStreamPhase::Ready) phase_ = PuckStreamPhase::Finishing;
  }

  void complete() {
    if (phase_ == PuckStreamPhase::Finishing) phase_ = PuckStreamPhase::Complete;
  }

  PuckStreamFailureAction fail() {
    const auto action = wasReady_
                            ? PuckStreamFailureAction::StopSession
                            : PuckStreamFailureAction::UseBatchFallback;
    phase_ = PuckStreamPhase::Failed;
    return action;
  }

 private:
  PuckStreamPhase phase_ = PuckStreamPhase::Idle;
  bool wasReady_ = false;
};
