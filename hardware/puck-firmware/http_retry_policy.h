#pragma once

struct HttpAttemptDecision {
  bool retry;
  bool resetClient;
};

inline HttpAttemptDecision decideHttpAttempt(int status, bool responseComplete) {
  bool failed = status == 0 || status >= 500 || !responseComplete;
  return {failed, failed};
}
