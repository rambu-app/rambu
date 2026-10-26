#include <cassert>

#include "../puck_runtime_state.h"

int main() {
  PuckRuntimeState state;

  assert(state.pressButton() == ManualAction::Start);
  assert(state.takePendingAction() == ManualAction::Start);
  assert(state.takePendingAction() == ManualAction::None);

  state.setListening(true);
  assert(state.pressButton() == ManualAction::Stop);
  assert(state.pressButton() == ManualAction::Stop);
  assert(state.takePendingAction() == ManualAction::Stop);
  assert(state.takePendingAction() == ManualAction::None);

  state.setListening(false);
  assert(state.pressButton() == ManualAction::Start);
  assert(state.takePendingAction() == ManualAction::Start);
}
