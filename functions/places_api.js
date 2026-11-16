// Google's Places API, signed in as this project's own server account (no key
// needed), once the API is turned on.

const { applicationDefault } = require("firebase-admin/app");
const { HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

const PROJECT = process.env.GCLOUD_PROJECT || "project-axis-app";

async function placesRequest(path, { body, mask }) {
  const { access_token: token } = await applicationDefault().getAccessToken();
  let res;
  try {
    res = await fetch(`https://places.googleapis.com/v1/${path}`, {
      method: body ? "POST" : "GET",
      headers: {
        "Authorization": `Bearer ${token}`,
        "X-Goog-User-Project": PROJECT,
        "X-Goog-FieldMask": mask,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(8000),
    });
  } catch (e) {
    throw new HttpsError("unavailable", `Couldn't reach Google (${e.message}).`);
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const reason = (json.error && json.error.message) || `Google answered ${res.status}`;
    logger.warn("places failed", { status: res.status, reason });
    if (/has not been used|is disabled|SERVICE_DISABLED/i.test(reason)) {
      throw new HttpsError("failed-precondition", "Google's Places API is off for this project, so addresses can't autocomplete yet.");
    }
    throw new HttpsError("unavailable", "Google couldn't suggest addresses just now.");
  }
  return json;
}

module.exports = { placesRequest };
