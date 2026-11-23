// Address suggestions as you type, from Google's Places API. Typing and then picking counts as one session, which is how Google bills it
// least: the suggestions are free when the pick is looked up with the same token.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { placesRequest: places } = require("./places_api");
const { normalizeSuggestions, placeZoneOf } = require("./trips_core");
const { requirePremiumBeta } = require("./premium");

// Addresses are for the calendar's events and Trips: premium beta's.

const session = (d) => (/^[\w-]{1,36}$/.test(String(d.session || "")) ? String(d.session) : undefined);

exports.placeSuggest = onCall({ timeoutSeconds: 15 }, async (request) => {
  requirePremiumBeta(request);
  const d = request.data || {};
  const input = String(d.input || "").trim().slice(0, 200);
  if (input.length < 3) return { suggestions: [] };
  const lat = Number(d.near && d.near.lat);
  const lng = Number(d.near && d.near.lng);
  const json = await places("places:autocomplete", {
    mask: "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text,suggestions.placePrediction.structuredFormat",
    body: {
      input,
      sessionToken: session(d),
      // Near the last address you picked; a preference, not a limit.
      ...(Number.isFinite(lat) && Number.isFinite(lng) && d.near ?
        { locationBias: { circle: { center: { latitude: lat, longitude: lng }, radius: 50000 } } } : {}),
    },
  });
  return { suggestions: normalizeSuggestions(json) };
});

/** Ends a typing session, and says where the pick is so later suggestions lean nearby. */
exports.placeDetails = onCall({ timeoutSeconds: 15 }, async (request) => {
  requirePremiumBeta(request);
  const d = request.data || {};
  const id = String(d.id || "");
  if (!/^[\w-]{1,500}$/.test(id)) throw new HttpsError("invalid-argument", "Which place?");
  const token = session(d);
  const json = await places(`places/${id}${token ? `?sessionToken=${token}` : ""}`, { mask: "location" });
  const l = json.location || {};
  return { lat: l.latitude, lng: l.longitude };
});

/** The time zone of a place, typed or picked: { zone }, null if Google can't tell. */
exports.placeZone = onCall({ timeoutSeconds: 15 }, async (request) => {
  requirePremiumBeta(request);
  const place = String((request.data && request.data.place) || "").trim().slice(0, 300);
  if (!place) throw new HttpsError("invalid-argument", "Which place?");
  const json = await places("places:searchText", { mask: "places.timeZone", body: { textQuery: place, pageSize: 1 } });
  return { zone: placeZoneOf(json) };
});
