// node test_refresh_limit.js — the cap on refreshing Canvas.
const assert = require("assert");
const { takeRefresh, waitText, WINDOW_MS } = require("./refresh_limit");

const now = 1_000_000_000;
const min = 60 * 1000;

// Nothing yet: fine, and remembered.
let r = takeRefresh(undefined, now);
assert.deepStrictEqual(r, { ok: true, times: [now] });

// Four in the last few minutes: the fifth is fine.
r = takeRefresh([now - 4 * min, now - 3 * min, now - 2 * min, now - min], now);
assert.strictEqual(r.ok, true);
assert.strictEqual(r.times.length, 5);

// Five in five minutes: the sixth waits until the oldest is five minutes old.
r = takeRefresh([now - 4 * min, now - 3 * min, now - 2 * min, now - min, now - 1000], now);
assert.strictEqual(r.ok, false);
assert.strictEqual(r.retryAt, now - 4 * min + WINDOW_MS);
assert.strictEqual(waitText(r.retryAt, now), "Canvas was refreshed 5 times in 5 minutes. Try again in 1 minute.");

// Older than five minutes doesn't count, and isn't kept.
r = takeRefresh([now - 10 * min, now - 6 * min, now - 5 * min - 1, now - min], now);
assert.deepStrictEqual(r, { ok: true, times: [now - min, now] });

// Junk in the stored list is ignored.
r = takeRefresh(["x", null, now + 99 * min], now);
assert.deepStrictEqual(r, { ok: true, times: [now] });

assert.strictEqual(waitText(now + 4 * min + 1, now), "Canvas was refreshed 5 times in 5 minutes. Try again in 5 minutes.");
console.log("refresh limit ok");
