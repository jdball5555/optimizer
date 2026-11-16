// node test_trips.js
const assert = require("assert");
const { cleanFlightNumber, normalizeFlight, leavingOn, seconds, planCommute, placeZoneOf } = require("./trips_core");

(async () => {
  assert.strictEqual(cleanFlightNumber("aa 0123"), "AA123");
  assert.strictEqual(cleanFlightNumber("UA1"), "UA1");
  assert.strictEqual(cleanFlightNumber("hello"), null);

  const f = normalizeFlight({
    number: "AA 1234",
    status: "Expected",
    airline: { name: "American Airlines" },
    aircraft: { model: "Boeing 737-800" },
    greatCircleDistance: { mile: 1235 },
    departure: {
      airport: { iata: "DFW", name: "Dallas Fort Worth", municipalityName: "Dallas", timeZone: "America/Chicago" },
      scheduledTime: { utc: "2026-12-20 14:05Z", local: "2026-12-20 08:05-06:00" },
      terminal: "D",
      gate: "D12",
    },
    arrival: { airport: { iata: "LAX", name: "Los Angeles" }, scheduledTime: { utc: "2026-12-20 17:30Z", local: "2026-12-20 09:30-08:00" }, baggageBelt: "4" },
  });
  assert.strictEqual(f.departure.scheduled, Date.parse("2026-12-20T14:05Z"));
  assert.strictEqual(f.departure.scheduledLocal, "2026-12-20T08:05");
  assert.strictEqual(f.arrival.scheduledLocal, "2026-12-20T09:30");
  assert.strictEqual(f.departure.gate, "D12");
  assert.strictEqual(f.arrival.baggageBelt, "4");
  assert.strictEqual(f.airline, "American Airlines");
  assert.strictEqual(f.departure.timeZone, "America/Chicago");
  const overnight = normalizeFlight({ departure: { scheduledTime: { local: "2026-12-19 23:30-06:00" } } });
  assert.deepStrictEqual(leavingOn([overnight, f], "2026-12-20"), [f], "one that left the day before isn't this date's");
  assert.deepStrictEqual(leavingOn([overnight], "2026-12-20"), [overnight], "better something than nothing");
  // A flight with hardly any data still reads.
  assert.strictEqual(normalizeFlight({}).departure.scheduled, null);

  assert.strictEqual(seconds("165s"), 165);
  assert.strictEqual(seconds(undefined), null);

  const now = Date.parse("2026-11-01T12:00Z");
  const hour = 3600 * 1000;
  const asked = [];
  // Traffic that gets worse the later you leave: 30 minutes, plus 10 per hour after now.
  const route = async (t) => {
    asked.push(t);
    const at = t.departureTime == null ? now : t.departureTime;
    return { seconds: 1800 + Math.round((at - now) / hour) * 600, meters: 1000 };
  };

  // Arrive by: leaves early enough for the traffic at the time it actually leaves.
  const arriveBy = now + 10 * hour;
  let r = await planCommute(route, { mode: "DRIVE", arriveBy, now });
  assert.strictEqual(r.arriveAt, arriveBy);
  assert.strictEqual(r.leaveAt, arriveBy - r.seconds * 1000);
  assert.ok(r.predicted);
  assert.ok(asked.every((t) => t.arrivalTime == null), "driving never asks Google for an arrival time");
  assert.ok(Math.abs((await route({ departureTime: r.leaveAt })).seconds - r.seconds) <= 600);

  // Leave at a future time asks for that time.
  r = await planCommute(route, { mode: "DRIVE", leaveAt: now + hour, now });
  assert.deepStrictEqual(asked.at(-1), { departureTime: now + hour });
  assert.strictEqual(r.arriveAt, now + hour + r.seconds * 1000);

  // Leave at nothing in particular: right now.
  r = await planCommute(route, { mode: "DRIVE", now });
  assert.deepStrictEqual(asked.at(-1), {});
  assert.strictEqual(r.leaveAt, now);

  // Google refuses past departures when driving: it asks about the same weekday
  // and time ahead, keeps the time you set, and says it wasn't for that exact time.
  const week = 7 * 24 * hour;
  r = await planCommute(route, { mode: "DRIVE", leaveAt: now - 2 * 24 * hour, now });
  assert.deepStrictEqual(asked.at(-1), { departureTime: now - 2 * 24 * hour + week });
  assert.strictEqual(r.leaveAt, now - 2 * 24 * hour, "the time you set stays yours");
  assert.strictEqual(r.predicted, false);
  r = await planCommute(route, { mode: "DRIVE", arriveBy: now - hour, now });
  assert.ok(asked.at(-1).departureTime > now, "never asks about the past");
  assert.strictEqual(r.arriveAt, now - hour);
  assert.strictEqual(r.predicted, false);

  // Arriving soon, but the drive means leaving in the past: still never asks about the past.
  r = await planCommute(async (t) => { asked.push(t); return { seconds: 5 * 3600, meters: 1 }; }, { mode: "DRIVE", arriveBy: now + hour, now });
  assert.ok(asked.slice(-3).every((t) => t.departureTime > now));
  assert.strictEqual(r.predicted, false);

  // Time at stops is part of the journey: it moves when you arrive, or when to leave.
  const fixed = async () => ({ seconds: 3600, meters: 1 });
  r = await planCommute(fixed, { mode: "DRIVE", leaveAt: now + hour, now, extra: 30 * 60000 });
  assert.strictEqual(r.arriveAt, now + hour + hour + 30 * 60000);
  const asking = [];
  r = await planCommute(async (t) => { asking.push(t); return { seconds: 3600, meters: 1 }; }, { mode: "DRIVE", arriveBy: now + 10 * hour, now, extra: 30 * 60000 });
  assert.strictEqual(r.leaveAt, now + 10 * hour - hour - 30 * 60000);
  assert.strictEqual(asking.at(-1).departureTime, r.leaveAt, "the traffic asked about is for when you'd really leave");

  // Transit can ask for an arrival directly.
  await planCommute(route, { mode: "TRANSIT", arriveBy, now });
  assert.deepStrictEqual(asked.at(-1), { arrivalTime: arriveBy });

  const { normalizeSuggestions } = require("./trips_core");
assert.deepStrictEqual(normalizeSuggestions({ suggestions: [
  { placePrediction: { placeId: "p1", text: { text: "Austin, TX, USA" }, structuredFormat: { mainText: { text: "Austin" }, secondaryText: { text: "TX, USA" } } } },
  { placePrediction: { placeId: "p2", text: { text: "Austin St" } } },
  { queryPrediction: { text: { text: "austin food" } } },
] }), [
  { id: "p1", text: "Austin, TX, USA", main: "Austin", secondary: "TX, USA" },
  { id: "p2", text: "Austin St", main: "Austin St", secondary: "" },
]);
assert.deepStrictEqual(normalizeSuggestions({}), []);
const { unplaced, bestPlace, routeOptions } = require("./trips_core");
assert.deepStrictEqual(routeOptions({ routes: [
  { description: "I-35 E", duration: "19920s", distanceMeters: 484000 },
  { description: "US-281 S", duration: "20340s", distanceMeters: 508000 },
  { description: "No time" },
] }), [{ name: "I-35 E", minutes: 332, meters: 484000 }, { name: "US-281 S", minutes: 339, meters: 508000 }]);
assert.deepStrictEqual(routeOptions({}), []);
assert.deepStrictEqual(unplaced({}), []);
assert.deepStrictEqual(unplaced({ geocodingResults: { intermediates: [{ geocoderStatus: {}, intermediateWaypointRequestIndex: 0 }, { geocoderStatus: { code: 5 }, intermediateWaypointRequestIndex: 1 }] } }), [1]);
assert.deepStrictEqual(unplaced({ geocodingResults: { origin: { geocoderStatus: {}, placeId: "a" }, destination: { geocoderStatus: { code: 5, message: "NOT_FOUND" } } } }), ["destination"]);
assert.deepStrictEqual(bestPlace({ places: [{ id: "p1", displayName: { text: "Alamodome" }, formattedAddress: "100 Montana St, San Antonio, TX 78203, USA" }] }),
  { placeId: "p1", text: "Alamodome, 100 Montana St, San Antonio, TX 78203, USA" });
assert.deepStrictEqual(bestPlace({ places: [{ id: "p2", displayName: { text: "9830 Great Hall Ln" }, formattedAddress: "9830 Great Hall Ln, Frisco, TX 75035, USA" }] }),
  { placeId: "p2", text: "9830 Great Hall Ln, Frisco, TX 75035, USA" });
assert.strictEqual(bestPlace({}), null);
assert.strictEqual(placeZoneOf({ places: [{ timeZone: { id: "America/Los_Angeles" } }] }), "America/Los_Angeles");
assert.strictEqual(placeZoneOf({ places: [{}] }), null);
assert.strictEqual(placeZoneOf({}), null);

// Sharing a trip: what each person's copy has in it.
const { roleOnItem, peopleOnItem, tripCopyFor, cleanSharedItem, cleanTripFields } = require("./trip_share_core");
{
  const everyone = [{ email: "ann@x.com", name: "Ann", role: "editor" }, { email: "bo@x.com", name: "", role: "viewer" }];
  const open = { id: "open", title: "Open" };
  const secret = { id: "secret", title: "Surprise party", access: { "bo@x.com": "none" } };
  const promoted = { id: "promoted", title: "Lunch", access: { "bo@x.com": "editor", "ann@x.com": "viewer" } };
  const trip = { title: "Trip", notes: "n", items: [open, secret, promoted] };
  const share = { id: "s1", ownerName: "Me", ownerEmail: "me@x.com" };

  assert.strictEqual(roleOnItem(open, "bo@x.com", "viewer"), "viewer", "goes by the trip");
  assert.strictEqual(roleOnItem(secret, "bo@x.com", "viewer"), "none", "unless the entry says otherwise");
  assert.strictEqual(roleOnItem(promoted, "bo@x.com", "viewer"), "editor");
  assert.strictEqual(roleOnItem(undefined, "bo@x.com", "editor"), "editor", "a new entry goes by the trip");
  assert.strictEqual(roleOnItem({ access: { "bo@x.com": "owner" } }, "bo@x.com", "viewer"), "viewer", "nonsense is ignored");
  assert.deepStrictEqual(peopleOnItem(secret, everyone).map((p) => p.email), ["ann@x.com"]);

  const bo = tripCopyFor(trip, everyone[1], everyone, share);
  assert.deepStrictEqual(bo.items.map((i) => i.id), ["open", "promoted"], "a hidden entry isn't in their copy at all");
  assert.ok(!JSON.stringify(bo).includes("Surprise party"), "nothing of it");
  assert.ok(!JSON.stringify(bo).includes("access"), "nor who was given what");
  assert.strictEqual(bo.items[1].myRole, "editor");
  assert.strictEqual(bo.myRole, "viewer");
  assert.strictEqual(bo.shareId, "s1");
  assert.strictEqual(bo.ownerName, "Me");
  assert.strictEqual(bo.notes, "n");
  const ann = tripCopyFor(trip, everyone[0], everyone, share);
  assert.deepStrictEqual(ann.items.map((i) => [i.id, i.myRole]), [["open", "editor"], ["secret", "editor"], ["promoted", "viewer"]]);
  assert.deepStrictEqual(ann.items[1].canSee.map((p) => p.email), ["ann@x.com"], "and who can see each");

  const time = (ms) => `t${ms}`;
  const item = cleanSharedItem({ id: "a", start: 5, end: 6, title: "x", access: { "ann@x.com": "editor" }, myRole: "editor", canSee: [] }, { id: "a", access: { "bo@x.com": "none" } }, time);
  assert.deepStrictEqual(item.access, { "bo@x.com": "none" }, "an editor can't change who sees it");
  assert.strictEqual(item.myRole, undefined);
  assert.strictEqual(item.canSee, undefined);
  assert.strictEqual(item.start, "t5");
  assert.strictEqual(cleanSharedItem({ id: "a", start: 5, end: 6, access: { "me@x.com": "editor" } }, null, time).access, undefined, "nor give themselves any on a new one");
  assert.strictEqual(cleanSharedItem({ id: "a", start: "soon", end: 6 }, null, time), null);
  assert.strictEqual(cleanSharedItem({ start: 5, end: 6 }, null, time), null);
  assert.strictEqual(cleanSharedItem("x", null, time), null);

  const fields = cleanTripFields({ title: "New", items: [], owner: "me", color: 5, links: [{ url: "https://a.com", label: "A" }, { url: "javascript:alert(1)" }] });
  assert.deepStrictEqual(fields, { title: "New", links: [{ url: "https://a.com", label: "A" }] }, "only what an editor may change, and only real links");
  assert.deepStrictEqual(cleanTripFields({ title: "  " }), {});
}

console.log("trips: ok");
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
