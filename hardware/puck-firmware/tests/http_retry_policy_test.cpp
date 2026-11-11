#include <cassert>

#include "../http_retry_policy.h"

int main() {
  HttpAttemptDecision noStatus = decideHttpAttempt(0, false);
  assert(noStatus.retry);
  assert(noStatus.resetClient);

  HttpAttemptDecision serverError = decideHttpAttempt(503, true);
  assert(serverError.retry);
  assert(serverError.resetClient);

  HttpAttemptDecision incompleteSuccess = decideHttpAttempt(200, false);
  assert(incompleteSuccess.retry);
  assert(incompleteSuccess.resetClient);

  HttpAttemptDecision success = decideHttpAttempt(200, true);
  assert(!success.retry);
  assert(!success.resetClient);

  HttpAttemptDecision notFound = decideHttpAttempt(404, true);
  assert(!notFound.retry);
  assert(!notFound.resetClient);
}
