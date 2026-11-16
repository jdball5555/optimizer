// node test_google.js
const assert = require("assert");
const { eventDoc, signature, zonedMidnight } = require("./google_events");

const cal = { key: "me@x.com|me@x.com", id: "me@x.com", account: "me@x.com", name: "Me", color: "#4285f4", timeZone: "America/Chicago" };

// All-day: carries its days, and starts at midnight in the calendar's zone (CST = UTC-6 in November).
const allDay = eventDoc({ id: "a1", summary: "Trip", start: { date: "2026-11-20" }, end: { date: "2026-11-22" } }, cal);
assert.strictEqual(allDay.date, "2026-11-20");
assert.strictEqual(allDay.endDate, "2026-11-22");
assert.strictEqual(allDay.start.toDate().toISOString(), "2026-11-20T06:00:00.000Z");
assert.strictEqual(zonedMidnight("2026-07-04", "America/Chicago"), Date.parse("2026-07-04T05:00:00Z")); // CDT

// Timed, with an event color and a missing title.
const timed = eventDoc({ id: "t1", summary: " ", colorId: "11", start: { dateTime: "2026-11-03T09:00:00-06:00" }, end: { dateTime: "2026-11-03T09:00:00-06:00" } }, cal);
assert.strictEqual(timed.title, "(No title)");
assert.strictEqual(timed.color, "#D50000");
assert.strictEqual(timed.end.toMillis() - timed.start.toMillis(), 15 * 60 * 1000);

// Cancelled events aren't stored; a changed time changes the signature.
assert.strictEqual(eventDoc({ id: "c", status: "cancelled", start: { date: "2026-11-01" } }, cal), null);
const moved = eventDoc({ id: "t1", summary: " ", colorId: "11", start: { dateTime: "2026-11-03T10:00:00-06:00" }, end: { dateTime: "2026-11-03T11:00:00-06:00" } }, cal);
assert.notStrictEqual(signature(timed), signature(moved));
assert.strictEqual(signature(timed), signature({ ...timed }));
console.log("google events: ok");
