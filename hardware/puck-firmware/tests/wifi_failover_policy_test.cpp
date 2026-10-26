#include <cassert>
#include <cstdint>

#include "../wifi_failover_policy.h"

int main() {
  assert(nextNetworkAfterTimeout(WifiNetwork::Primary, true) == WifiNetwork::Backup);
  assert(nextNetworkAfterTimeout(WifiNetwork::Primary, false) == WifiNetwork::Primary);
  assert(nextNetworkAfterTimeout(WifiNetwork::Backup, true) == WifiNetwork::Primary);

  constexpr uint32_t interval = 300000;
  assert(!shouldProbePrimary(WifiNetwork::Primary, false, 100, 100 + interval, interval));
  assert(!shouldProbePrimary(WifiNetwork::Backup, true, 100, 100 + interval, interval));
  assert(!shouldProbePrimary(WifiNetwork::Backup, false, 100, 100 + interval - 1, interval));
  assert(shouldProbePrimary(WifiNetwork::Backup, false, 100, 100 + interval, interval));

  const uint32_t connectedNearWrap = UINT32_MAX - 100;
  const uint32_t nowAfterWrap = interval - 101;
  assert(shouldProbePrimary(
      WifiNetwork::Backup, false, connectedNearWrap, nowAfterWrap, interval));
}
