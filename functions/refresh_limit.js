// How often someone can ask for their Canvas calendars to be checked.
//
// Without premium beta Canvas is only checked when the app opens or you tap
// refresh (no check every minute), so each check is a function call made on
// request. Five in five minutes is plenty for real use; past that, the next
// one waits until the oldest of those five is five minutes old.

const LIMIT = 5;
const WINDOW_MS = 5 * 60 * 1000;

/**
 * Given the times (ms) of recent refreshes and now, whether this one may go
 * ahead. Returns { ok, times } with the times to keep (this one included when
 * ok), or { ok: false, retryAt } with when the next one may.
 */
function takeRefresh(times, now) {
  const recent = (Array.isArray(times) ? times : [])
    .filter((t) => typeof t === "number" && t > now - WINDOW_MS && t <= now)
    .sort((a, b) => a - b);
  if (recent.length >= LIMIT) {
    return { ok: false, retryAt: recent[recent.length - LIMIT] + WINDOW_MS };
  }
  return { ok: true, times: [...recent, now] };
}

/** "Try again in 4 minutes." */
function waitText(retryAt, now) {
  const min = Math.max(1, Math.ceil((retryAt - now) / 60000));
  return `Canvas was refreshed ${LIMIT} times in ${WINDOW_MS / 60000} minutes. Try again in ${min} minute${min === 1 ? "" : "s"}.`;
}

module.exports = { LIMIT, WINDOW_MS, takeRefresh, waitText };
