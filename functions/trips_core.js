// The parts of trip planning that need no network: reading flight data, and
// working out when to leave. Kept apart from trips.js so they can be tested.

const FLIGHT_NUMBER = /^([A-Z0-9]{2,3})\s*0*(\d{1,4}[A-Z]?)$/;

/** "aa 0123" → "AA123", or null if it doesn't look like a flight number. */
function cleanFlightNumber(raw) {
  const m = FLIGHT_NUMBER.exec(String(raw || "").trim().toUpperCase());
  return m ? `${m[1]}${m[2]}` : null;
}

// AeroDataBox writes times like "2026-12-20 10:30Z" and "2026-12-20 04:30-06:00".
function epoch(v) {
  if (!v) return null;
  const t = Date.parse(String(v).trim().replace(" ", "T"));
  return Number.isNaN(t) ? null : t;
}

/** The clock time at the airport, without its offset: "2026-12-20T04:30". */
function localClock(v) {
  const s = String(v || "").trim().replace(" ", "T");
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(s) ? s.slice(0, 16) : null;
}

function movement(m) {
  const leg = m || {};
  const a = leg.airport || {};
  const scheduled = leg.scheduledTime || {};
  const revised = leg.revisedTime || {};
  return {
    iata: a.iata || a.icao || "",
    name: a.name || a.shortName || "",
    city: a.municipalityName || "",
    timeZone: a.timeZone || "",
    scheduled: epoch(scheduled.utc || leg.scheduledTimeUtc),
    scheduledLocal: localClock(scheduled.local || leg.scheduledTimeLocal),
    revised: epoch(revised.utc || leg.actualTimeUtc),
    revisedLocal: localClock(revised.local || leg.actualTimeLocal),
    terminal: leg.terminal || "",
    gate: leg.gate || "",
    checkInDesk: leg.checkInDesk || "",
    baggageBelt: leg.baggageBelt || "",
  };
}

/** One flight (or leg) from AeroDataBox, in the shape the app stores. */
function normalizeFlight(raw) {
  const f = raw || {};
  return {
    number: String(f.number || "").replace(/\s+/g, " ").trim(),
    airline: (f.airline && f.airline.name) || "",
    aircraft: (f.aircraft && f.aircraft.model) || "",
    status: f.status || "",
    miles: (f.greatCircleDistance && f.greatCircleDistance.mile) || null,
    departure: movement(f.departure),
    arrival: movement(f.arrival),
  };
}

/** The ones leaving on [date] by the airport's own clock, in case a flight that only lands that day came too. */
function leavingOn(flights, date) {
  const leaving = flights.filter((f) => String(f.departure.scheduledLocal || "").startsWith(date));
  return leaving.length ? leaving : flights;
}

/** "1234s" → 1234. */
function seconds(duration) {
  const n = parseInt(String(duration || "").replace(/s$/, ""), 10);
  return Number.isNaN(n) ? null : n;
}

/**
 * When to leave and arrive. [route] asks Google for one route, given
 * { departureTime } or { arrivalTime } in ms (or neither, meaning now), and
 * returns { seconds, meters }.
 *
 * Google predicts traffic from a departure time, and only transit can be asked
 * for an arrival. So to arrive by a time when driving, guess a departure, see
 * how long that takes, and leave that much earlier; the second pass settles it.
 */
async function planCommute(route, { mode, leaveAt, arriveBy, now, extra = 0 }) {
  const transit = mode === "TRANSIT";
  // Only transit can look at the past. For driving, a time that's gone is asked
  // about at the same weekday and time ahead, whose traffic is the closest match.
  const exact = (t) => transit || t > now;
  const when = (t) => {
    let at = t;
    while (!exact(at)) at += 7 * 24 * 3600 * 1000;
    return { departureTime: at };
  };

  if (arriveBy == null) {
    if (leaveAt == null) {
      const r = await route({});
      return { ...r, leaveAt: now, arriveAt: now + r.seconds * 1000, predicted: false };
    }
    const r = await route(when(leaveAt));
    return { ...r, leaveAt, arriveAt: leaveAt + r.seconds * 1000 + extra, predicted: exact(leaveAt) };
  }
  if (transit) {
    const r = await route({ arrivalTime: arriveBy });
    return { ...r, leaveAt: arriveBy - r.seconds * 1000, arriveAt: arriveBy, predicted: true };
  }
  // Driving can't ask for an arrival: guess when you'd leave, then ask again for
  // that time, since the traffic then is what decides how long it takes.
  let r = await route(when(arriveBy - extra - 3600 * 1000));
  for (let i = 0; i < 2; i++) r = await route(when(arriveBy - extra - r.seconds * 1000));
  const leave = arriveBy - extra - r.seconds * 1000;
  return { ...r, leaveAt: leave, arriveAt: arriveBy, predicted: exact(leave) };
}

/** Google's routes for a trip as choices, its pick first: [{ name, minutes, meters }]. */
function routeOptions(json) {
  return ((json && json.routes) || [])
    .map((r) => ({ name: r.description || "", secs: seconds(r.duration), meters: r.distanceMeters || 0 }))
    .filter((r) => r.secs != null)
    .map((r) => ({ name: r.name, minutes: Math.max(1, Math.round(r.secs / 60)), meters: r.meters }));
}

/** Which places on a route Google couldn't find, from its geocodingResults: "origin", "destination" or a stop's index. */
function unplaced(json) {
  const g = (json && json.geocodingResults) || {};
  const failed = (w) => w && w.geocoderStatus && w.geocoderStatus.code;
  return [
    ...["origin", "destination"].filter((k) => failed(g[k])),
    ...(g.intermediates || []).filter(failed).map((w) => w.intermediateWaypointRequestIndex || 0),
  ];
}

/** Google's best match for a typed place, as a route's end and how to show it: { placeId, text }, or null. */
function bestPlace(json) {
  const p = ((json && json.places) || [])[0];
  if (!p || !p.id) return null;
  const name = (p.displayName && p.displayName.text) || "";
  const address = p.formattedAddress || name;
  return { placeId: p.id, text: name && !address.startsWith(name) ? `${name}, ${address}` : address };
}

/** The IANA time zone of the first place in a search answer, or null. */
function placeZoneOf(json) {
  const p = ((json && json.places) || [])[0];
  return (p && p.timeZone && p.timeZone.id) || null;
}

/** Google's autocomplete answer → { id, text, main, secondary }, skipping anything that isn't a place. */
function normalizeSuggestions(json) {
  const out = [];
  for (const s of (json && json.suggestions) || []) {
    const p = s.placePrediction;
    if (!p || !p.placeId || !p.text || !p.text.text) continue;
    const f = p.structuredFormat || {};
    out.push({
      id: p.placeId,
      text: p.text.text,
      main: (f.mainText && f.mainText.text) || p.text.text,
      secondary: (f.secondaryText && f.secondaryText.text) || "",
    });
  }
  return out;
}

module.exports = { cleanFlightNumber, normalizeFlight, leavingOn, seconds, planCommute, normalizeSuggestions, unplaced, bestPlace, routeOptions, placeZoneOf };
