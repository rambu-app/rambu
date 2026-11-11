#include <cassert>

#include "../puck_stream_state.h"

int main() {
  PuckStreamState stream;
  assert(stream.phase() == PuckStreamPhase::Idle);
  assert(!stream.canSendAudio());

  stream.begin();
  assert(stream.phase() == PuckStreamPhase::Connecting);
  assert(!stream.canSendAudio());
  assert(stream.fail() == PuckStreamFailureAction::UseBatchFallback);
  assert(stream.phase() == PuckStreamPhase::Failed);

  stream.begin();
  stream.ready();
  assert(stream.phase() == PuckStreamPhase::Ready);
  assert(stream.canSendAudio());
  assert(!stream.canSendFinish());

  stream.finalAudioSent();
  assert(stream.canSendFinish());

  stream.beginFinish();
  assert(stream.phase() == PuckStreamPhase::Finishing);
  assert(!stream.canSendAudio());

  stream.complete();
  assert(stream.phase() == PuckStreamPhase::Complete);

  stream.begin();
  stream.ready();
  assert(stream.fail() == PuckStreamFailureAction::StopSession);
  assert(stream.phase() == PuckStreamPhase::Failed);
}
