// Optimizer's trip planning: looking up flights and asking Google how long a
// commute takes. The trips themselves are in optimizer/{uid}/trips, which the
// app reads and writes directly; these only fetch from outside services.
//
//   Flights: AeroDataBox (through RapidAPI). Until there's a key, lookups say
//     they aren't set up. To turn on: `firebase functions:secrets:set
//     AERODATABOX_KEY`, then uncomment `secrets` on lookupFlight and redeploy.
//   Commutes: Google's Routes API, signed in as this project's own server
//     account (no key needed), once the API is turned on for the project.

const { applicationDefault } = require("firebase-admin/app");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { cleanFlightNumber, normalizeFlight, leavingOn, seconds, planCommute, unplaced, bestPlace, routeOptions } = require("./trips_core");
const { placesRequest } = require("./places_api");

const PROJECT = process.env.GCLOUD_PROJECT || "project-axis-app";

function requireUid(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  return request.auth.uid;
}

/** Every leg flying under a flight number on a date (the date at the departure airport). */
exports.lookupFlight = onCall({ /* secrets: ["AERODATABOX_KEY"], */ timeoutSeconds: 30 }, async (request) => {
  requireUid(request);
  const number = cleanFlightNumber(request.data && request.data.number);
  const date = String((request.data && request.data.date) || "");
  if (!number) throw new HttpsError("invalid-argument", "That doesn't look like a flight number. Try something like AA 1234.");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new HttpsError("invalid-argument", "Pick the date of the flight.");
  const key = process.env.AERODATABOX_KEY;
  if (!key) {
    throw new HttpsError("failed-precondition", "Flight lookup isn't set up yet, so fill in the details below.");
  }
  let res;
  try {
    res = await fetch(`https://aerodatabox.p.rapidapi.com/flights/number/${number}/${date}?dateLocalRole=Departure&withAircraftImage=false&withLocation=true`, {
      headers: { "X-RapidAPI-Key": key, "X-RapidAPI-Host": "aerodatabox.p.rapidapi.com" },
      signal: AbortSignal.timeout(20000),
    });
  } catch (e) {
    throw new HttpsError("unavailable", `Couldn't reach the flight service (${e.message}).`);
  }
  if (res.status === 204 || res.status === 404) {
    throw new HttpsError("not-found", `No flight ${number} found on ${date}. Schedules may not be published that far ahead; you can fill in the details below.`);
  }
  if (!res.ok) {
    logger.warn("flight lookup failed", { status: res.status, body: (await res.text()).slice(0, 300) });
    throw new HttpsError("unavailable", res.status === 429 ?
      "The flight service's monthly limit is used up. Fill in the details below for now." :
      `The flight service answered ${res.status}. Fill in the details below for now.`);
  }
  const body = await res.json().catch(() => []);
  return { flights: leavingOn((Array.isArray(body) ? body : []).map(normalizeFlight), date) };
});

/** Google had no route. [failed] says which places it couldn't find. */
class NoRoute extends Error {
  constructor(failed) {
    super("no route");
    this.failed = failed;
  }
}

/** Waypoints are { address } or { placeId }. */
async function googleRoute({ origin, destination, stops = [], mode }, times) {
  const { access_token: token } = await applicationDefault().getAccessToken();
  const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "X-Goog-User-Project": PROJECT,
      "X-Goog-FieldMask": "routes.duration,routes.distanceMeters,routes.legs.duration,routes.description,geocodingResults",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      origin,
      destination,
      // Google has no alternatives for a route with stops.
      ...(stops.length ? { intermediates: stops } : mode === "DRIVE" ? { computeAlternativeRoutes: true } : {}),
      travelMode: mode,
      // Predicted traffic for that time of that day, from Google's history.
      ...(mode === "DRIVE" ? { routingPreference: "TRAFFIC_AWARE_OPTIMAL", trafficModel: "BEST_GUESS" } : {}),
      ...(times.departureTime != null ? { departureTime: new Date(times.departureTime).toISOString() } : {}),
      ...(times.arrivalTime != null ? { arrivalTime: new Date(times.arrivalTime).toISOString() } : {}),
    }),
    signal: AbortSignal.timeout(20000),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const message = (json.error && json.error.message) || `Google answered ${res.status}`;
    logger.warn("route failed", { status: res.status, reason: message });
    if (/has not been used|is disabled|SERVICE_DISABLED/i.test(message)) {
      throw new HttpsError("failed-precondition", "Google's Routes API is off for this project, so type the travel time in for now.");
    }
    throw new HttpsError("failed-precondition", `Google couldn't work that out: ${message}`);
  }
  const route = (json.routes || [])[0];
  const secs = route && seconds(route.duration);
  if (secs == null) throw new NoRoute(unplaced(json));
  return { seconds: secs, meters: route.distanceMeters || 0, legs: (route.legs || []).map((l) => seconds(l.duration) || 0), routes: routeOptions(json) };
}

/** What Google Maps' search makes of a typed place, or null if it can't tell (or Places is off). */
async function findPlace(text) {
  try {
    return bestPlace(await placesRequest("places:searchText", {
      mask: "places.id,places.displayName,places.formattedAddress",
      body: { textQuery: text, pageSize: 1 },
    }));
  } catch (e) {
    logger.info("couldn't look up a place", { reason: e.message });
    return null;
  }
}

/** How long a commute takes at that time of that day: { minutes, meters, leaveAt, arriveAt, predicted }, and { from, to } if it had to work out what you typed. */
exports.commuteTime = onCall({ timeoutSeconds: 60 }, async (request) => {
  requireUid(request);
  const d = request.data || {};
  const from = String(d.from || "").trim().slice(0, 300);
  const to = String(d.to || "").trim().slice(0, 300);
  const mode = ["DRIVE", "TRANSIT", "WALK", "BICYCLE"].includes(d.mode) ? d.mode : "DRIVE";
  if (!from || !to) throw new HttpsError("invalid-argument", "Fill in where you're leaving from and where you're going.");
  const leaveAt = d.leaveAt == null ? null : Number(d.leaveAt);
  const arriveBy = d.arriveBy == null ? null : Number(d.arriveBy);
  // Places to stop at on the way, and the time spent at stops.
  const stops = (Array.isArray(d.stops) ? d.stops : []).slice(0, 8).map((s) => String(s || "").trim().slice(0, 300)).filter(Boolean);
  const extra = Math.min(Math.max(Number(d.stopMinutes) || 0, 0), 7 * 24 * 60) * 60000;
  const plan = (origin, destination, via) =>
    planCommute((times) => googleRoute({ origin, destination, stops: via, mode }, times), { mode, leaveAt, arriveBy, now: Date.now(), extra });
  const answer = (r, understood = {}) => ({
    minutes: Math.max(1, Math.round(r.seconds / 60)),
    meters: r.meters,
    legs: r.legs,
    routes: r.routes,
    leaveAt: r.leaveAt,
    arriveAt: r.arriveAt,
    predicted: r.predicted,
    ...understood,
  });
  try {
    try {
      return answer(await plan({ address: from }, { address: to }, stops.map((address) => ({ address }))));
    } catch (e) {
      if (!(e instanceof NoRoute)) throw e;
      // Routes wants an exact address. Maps forgives typos and missing cities,
      // so ask its search what these mean, and say what it understood.
      const [start, end, ...via] = await Promise.all([from, to, ...stops].map(findPlace));
      if (!start || !end || via.some((p) => !p)) throw e;
      return answer(await plan({ placeId: start.placeId }, { placeId: end.placeId }, via.map((p) => ({ placeId: p.placeId }))), {
        from: start.text,
        to: end.text,
        stops: via.map((p) => p.text),
      });
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    if (e instanceof NoRoute) {
      logger.info("no route", { failed: e.failed });
      const names = { origin: from, destination: to, ...stops };
      throw new HttpsError("not-found", e.failed.length ?
        `Google couldn't find ${e.failed.map((k) => `“${names[k]}”`).join(" or ")}. Check the spelling, or add the city.` :
        "Google couldn't find a route between those places. Check the spelling, or add the city.");
    }
    logger.warn("commute failed", { message: e.message });
    throw new HttpsError("unavailable", `Couldn't reach Google (${e.message}).`);
  }
});
