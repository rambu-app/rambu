#include <cassert>

#include "../wifi_retry_policy.h"

int main() {
  assert(!shouldRetryWifi(0, 30000, 20000));
  assert(!shouldRetryWifi(1000, 20999, 20000));
  assert(shouldRetryWifi(1000, 21001, 20000));
  assert(shouldRetryWifi(0xfffffff0u, 25u, 20u));
}
