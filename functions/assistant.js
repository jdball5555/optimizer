// Optimizer's built-in assistant: Gemini on Vertex AI, signed in as this
// project's own server account, so no API key lives in the app or here.
//
// The app sends the conversation so far, its instructions and the tools it
// offers (calendar, to-dos, ...). Gemini either answers or asks for tools to
// be run; the app runs them on the user's own data and calls back with the
// results. This function only relays: it never touches the user's data.
//
//   optimizer/{uid}/aiUsage/{yyyy-mm-dd}   calls today, to cap runaway costs

const { applicationDefault } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { hasPremiumBeta } = require("./premium");

const PROJECT = process.env.GCLOUD_PROJECT || "project-axis-app";
// Tried in order: a model that isn't offered (404) falls through to the next.
const MODELS = (process.env.ASSISTANT_MODELS || "gemini-3.8-flash,gemini-3.5-flash")
  .split(",").map((s) => s.trim()).filter(Boolean);
// Each message can take several calls (one per round of tools).
const DAILY_LIMIT = Number(process.env.ASSISTANT_DAILY_LIMIT || 600);

async function generate(model, body) {
  const { access_token: token } = await applicationDefault().getAccessToken();
  const url = `https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/${model}:generateContent`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(100000),
  });
  const json = await res.json().catch(() => ({}));
  return { res, json };
}

/** Counts this call against today's limit; false once it's used up. */
async function withinLimit(uid) {
  const db = getFirestore();
  const day = new Date().toISOString().slice(0, 10);
  const ref = db.collection("optimizer").doc(uid).collection("aiUsage").doc(day);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const calls = (snap.exists ? Number(snap.data().calls) || 0 : 0) + 1;
    if (calls > DAILY_LIMIT) return false;
    tx.set(ref, { calls, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    return true;
  });
}

exports.assistant = onCall({ timeoutSeconds: 120, memory: "512MiB" }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  // A premium beta feature: only accounts switched on in Optic (optic.js).
  if (!hasPremiumBeta(request.auth)) {
    throw new HttpsError("permission-denied", "The assistant is part of Optimizer's premium beta, which isn't on for this account.");
  }
  const d = request.data || {};
  const contents = Array.isArray(d.contents) ? d.contents : null;
  if (!contents || contents.length === 0 || contents.length > 400) {
    throw new HttpsError("invalid-argument", "Nothing to send.");
  }
  if (JSON.stringify(d).length > 4000000) {
    throw new HttpsError("invalid-argument", "This chat has grown too long. Start a new one.");
  }
  if (!(await withinLimit(request.auth.uid))) {
    throw new HttpsError("resource-exhausted", "You've reached today's assistant limit. It resets at midnight UTC.");
  }

  const tools = Array.isArray(d.tools) ? d.tools.slice(0, 64) : [];
  const body = {
    contents,
    ...(d.system ? { systemInstruction: { parts: [{ text: String(d.system) }] } } : {}),
    ...(tools.length ? {
      tools: [{ functionDeclarations: tools }],
      toolConfig: { functionCallingConfig: { mode: "AUTO" } },
    } : {}),
    generationConfig: { maxOutputTokens: 8192 },
  };

  for (const model of MODELS) {
    let r;
    try {
      r = await generate(model, body);
    } catch (e) {
      throw new HttpsError("unavailable", `Couldn't reach Gemini (${e.message}).`);
    }
    const { res, json } = r;
    if (res.ok) {
      const c = (json.candidates || [])[0];
      if (!c || !c.content) {
        const why = (json.promptFeedback && json.promptFeedback.blockReason) || (c && c.finishReason) || "no answer";
        return { content: null, blocked: String(why), model };
      }
      return { content: c.content, finishReason: c.finishReason || null, model };
    }
    const reason = (json.error && json.error.message) || `Gemini answered ${res.status}`;
    logger.warn("assistant failed", { model, status: res.status, reason });
    if (res.status === 404) continue;
    if (/has not been used|is disabled|SERVICE_DISABLED/i.test(reason)) {
      throw new HttpsError("failed-precondition", "The Vertex AI API is off for this project, so the assistant can't answer yet.");
    }
    if (res.status === 429) throw new HttpsError("resource-exhausted", "Gemini is busy right now. Try again in a moment.");
    if (res.status === 400) throw new HttpsError("invalid-argument", `Gemini couldn't read that request: ${reason}`);
    if (res.status === 403) throw new HttpsError("permission-denied", `Gemini refused the server's access: ${reason}`);
    throw new HttpsError("unavailable", `Gemini error ${res.status}. Try again in a moment.`);
  }
  throw new HttpsError("failed-precondition", `None of these Gemini models are available: ${MODELS.join(", ")}.`);
});
