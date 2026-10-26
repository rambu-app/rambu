#include <cassert>
#include <thread>

#include "../call_alert_subscription.h"

int main() {
  CallAlertSubscription subscription;

  subscription.authenticated();
  subscription.authenticated();
  assert(subscription.takePendingAttempt());
  assert(!subscription.takePendingAttempt());

  subscription.authenticated();
  assert(!subscription.takePendingAttempt());

  subscription.disconnected();
  subscription.authenticated();
  assert(subscription.takePendingAttempt());
  assert(!subscription.takePendingAttempt());

  CallAlertSubscription concurrentSubscription;
  std::thread callbackTask([&] {
    for (int i = 0; i < 10000; ++i) {
      concurrentSubscription.authenticated();
      concurrentSubscription.disconnected();
    }
  });
  std::thread loopTask([&] {
    for (int i = 0; i < 10000; ++i) {
      concurrentSubscription.takePendingAttempt();
    }
  });
  callbackTask.join();
  loopTask.join();
}
