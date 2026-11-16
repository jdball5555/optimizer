// Optimizer's Google Calendar sync. It runs here, on the server, so every
// device (the Android app included) sees the same up-to-date calendar from
// Firestore without talking to Google itself.
//
//   optimizerSecrets/{uid}/googleAccounts/{id}  one linked Google account: its lasting sign-in
//                                               (refresh token) and `seen` (what each event looked
//                                               like last check). No security rule lets an app read it.
//   axisCalendar/{uid}                          accounts, calendars, googleLinks (per account: linked,
//                                               lastSync, error), autoSync, and keepPast (below)
//   axisCalendar/{uid}/events/{calendarKey|id}  every event from 6 weeks back to 6 months ahead
//
// Every minute pollGoogleCalendars checks each linked account. A check where
// nothing changed costs one Firestore read per account and no writes.
//
// With keepPast on, an event that's over is kept in Optimizer as it was:
// changing or deleting it in Google no longer touches it. A calendar that
// shows up new (keepPast on) has its past events held back until you say
// whether to save them (pastPending → resolvePastEvents).

const crypto = require("crypto");
const { eventDoc, signature, millis } = require("./google_events");
const { getFirestore, FieldValue, FieldPath, Timestamp } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

// The "Web client (auto created by Google Service)" OAuth client, the same one
// the app signs in with. Its secret is set once with
//   firebase functions:secrets:set GOOGLE_OAUTH_CLIENT_SECRET
const CLIENT_ID = defineString("GOOGLE_OAUTH_CLIENT_ID");
const CLIENT_SECRET = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");
const SCOPE = "https://www.googleapis.com/auth/calendar";

const db = getFirestore();
const DAY = 24 * 60 * 60 * 1000;
// The window kept in Firestore (CalendarService.syncedDays in the app matches).
const BACK_DAYS = 42;
const AHEAD_DAYS = 180;

const sha = (s) => crypto.createHash("sha1").update(s).digest("hex");
const userDoc = (uid) => db.collection("axisCalendar").doc(uid);
const accountsOf = (uid) => db.collection("optimizerSecrets").doc(uid).collection("googleAccounts");
const accountId = (email) => sha(email.toLowerCase()).slice(0, 20);
// Firestore ids can't contain '/'.
const eventDocId = (calendarKey, eventId) => `${calendarKey}|${eventId}`.replace(/\//g, "_");
// The calendar part of an event doc id (Google event ids never contain '|').
const calendarOfDocId = (id) => id.slice(0, id.lastIndexOf("|"));
const safeKey = (calendarKey) => calendarKey.replace(/\//g, "_");

class GoogleError extends Error {
  constructor(status, message, reason) {
    super(message);
    this.status = status;
    this.reason = reason;
  }
}

// ---------------------------------------------------------------- Google sign-in

async function tokenRequest(params) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: CLIENT_ID.value(), client_secret: CLIENT_SECRET.value(), ...params }),
    signal: AbortSignal.timeout(15000),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new GoogleError(res.status, json.error_description || json.error || `Google answered ${res.status}`, json.error);
  }
  return json;
}

// Access tokens last an hour; keep them while this server instance is warm.
const accessTokens = new Map();

async function accessToken(uid, acct) {
  const k = `${uid}|${acct.email}`;
  const cached = accessTokens.get(k);
  if (cached && cached.refreshToken === acct.refreshToken && cached.expires > Date.now() + 60 * 1000) return cached.token;
  const r = await tokenRequest({ grant_type: "refresh_token", refresh_token: acct.refreshToken });
  accessTokens.set(k, { token: r.access_token, refreshToken: acct.refreshToken, expires: Date.now() + (r.expires_in || 3600) * 1000 });
  return r.access_token;
}

// ---------------------------------------------------------------- Google Calendar API

/** Google's error, in words, with the fix for the setup problems people hit. */
function explain(status, json) {
  const err = (json && json.error) || {};
  let reason = "";
  for (const d of err.details || []) if (d && d.reason) reason = d.reason;
  for (const e of err.errors || []) if (e && e.reason && !reason) reason = e.reason;
  if (reason === "SERVICE_DISABLED" || reason === "accessNotConfigured") {
    return "The Google Calendar API is turned off for the Axis project. Turn it on at " +
      "console.cloud.google.com/apis/library/calendar-json.googleapis.com?project=project-axis-app.";
  }
  if (reason === "ACCESS_TOKEN_SCOPE_INSUFFICIENT" || reason === "insufficientPermissions") {
    return "Google didn't give calendar access. Connect again and tick the calendar box.";
  }
  return `Google Calendar error ${status}: ${err.message || "unknown"}`;
}

async function google(token, method, path, { query, body } = {}) {
  const url = new URL(`https://www.googleapis.com/calendar/v3/${path}`);
  for (const [k, v] of Object.entries(query || {})) url.searchParams.set(k, v);
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  // Already gone is as good as deleted.
  if (method === "DELETE" && (res.status === 404 || res.status === 410)) return null;
  const text = await res.text();
  let json = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch (_) {
    // not JSON
  }
  if (!res.ok) throw new GoogleError(res.status, explain(res.status, json));
  return json;
}

async function listAll(token, path, query) {
  const out = [];
  let pageToken;
  do {
    const page = await google(token, "GET", path, { query: { ...query, ...(pageToken ? { pageToken } : {}) } });
    out.push(...(page.items || []));
    pageToken = page.nextPageToken;
  } while (pageToken);
  return out;
}

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let i = 0;
  const worker = async () => {
    while (i < items.length) {
      const n = i++;
      out[n] = await fn(items[n]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const enc = encodeURIComponent;

// ---------------------------------------------------------------- events in Firestore

async function commit(writes) {
  for (let i = 0; i < writes.length; i += 400) {
    const batch = db.batch();
    writes.slice(i, i + 400).forEach((w) => w(batch));
    await batch.commit();
  }
}

function calendarEntry(email, c) {
  return {
    key: `${email}|${c.id}`,
    id: c.id,
    account: email,
    name: c.summaryOverride || c.summary || c.id,
    color: c.backgroundColor || "#4285F4",
    primary: !!c.primary,
    accessRole: c.accessRole || "reader",
    timeZone: c.timeZone || null,
  };
}

/**
 * Puts [email]'s calendars into the user's calendar list, replacing what that
 * account had. Keeping the past, a calendar gone from Google stays listed
 * (read-only) so its saved events still show.
 */
async function saveCalendars(uid, email, cals, keepPast = false) {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userDoc(uid));
    const d = snap.data() || {};
    const keys = new Set(cals.map((c) => c.key));
    const others = [];
    for (const c of d.calendars || []) {
      if (!c) continue;
      if (c.account !== email) others.push(c);
      else if (keepPast && !keys.has(c.key)) others.push({ ...c, gone: true, accessRole: "reader" });
    }
    const accounts = (d.accounts || []).includes(email) ? d.accounts : [...(d.accounts || []), email];
    tx.set(userDoc(uid), { calendars: [...others, ...cals], accounts }, { merge: true });
  });
}

function setLink(uid, email, link) {
  return userDoc(uid).set({ googleLinks: { [email]: link } }, { merge: true });
}

/**
 * Brings one account's events in Firestore up to date with Google.
 *
 * Normally it compares with `seen`, so an unchanged calendar costs nothing.
 * [full] compares with what's actually stored instead (when linking, and when
 * you press Sync), which also tidies up anything left over. [range] syncs a
 * span outside the usual window, for when you look far ahead or back.
 */
async function syncAccount(uid, ref, acct, { full = false, range = null, settings = null } = {}) {
  const email = acct.email;
  const prefs = settings || (await userDoc(uid).get()).data() || {};
  const keepPast = prefs.keepPast === true;
  let token;
  try {
    token = await accessToken(uid, acct);
  } catch (e) {
    if (e.reason === "invalid_grant") {
      // Access was removed in the Google account, or the sign-in expired.
      await ref.update({ revoked: true });
      await setLink(uid, email, { linked: false, error: "Google access ended. Connect this account again.", lastSync: null });
    }
    throw e;
  }

  const listed = await listAll(token, "users/me/calendarList", { maxResults: "250" });
  const cals = listed.filter((c) => !c.deleted).map((c) => calendarEntry(email, c));
  const calSig = sha(JSON.stringify(cals)).slice(0, 12);
  if (calSig !== acct.calendarsSig || full) await saveCalendars(uid, email, cals, keepPast);

  const now = Date.now();
  // Calendars new since last time (all of them, just linked). Keeping the
  // past, their past events wait for you to say whether to save them.
  const known = acct.calendarKeys ? new Set(acct.calendarKeys) : null;
  const added = known ? cals.filter((c) => !known.has(c.key)).map((c) => safeKey(c.key)) : [];
  const pending = new Set([...(prefs.pastPending || []), ...(keepPast ? added : [])]);
  if (keepPast && added.length) await userDoc(uid).set({ pastPending: FieldValue.arrayUnion(...added) }, { merge: true });
  const skippedBefore = prefs.pastSkippedBefore || {};
  const over = (end) => keepPast && end <= now;
  const window = range || { from: now - BACK_DAYS * DAY, to: now + AHEAD_DAYS * DAY };
  const inWindow = (ms) => ms >= window.from && ms < window.to;

  const results = await mapLimit(cals, 4, async (cal) => {
    try {
      const items = await listAll(token, `calendars/${enc(cal.id)}/events`, {
        timeMin: new Date(window.from).toISOString(),
        timeMax: new Date(window.to).toISOString(),
        singleEvents: "true",
        maxResults: "2500",
      });
      return { cal, items };
    } catch (e) {
      return { cal, error: e };
    }
  });

  const fresh = new Map(); // doc id → { doc, sig }
  const answered = new Set();
  const errors = [];
  for (const r of results) {
    if (r.error) {
      errors.push(`${r.cal.name}: ${r.error.message}`);
      continue;
    }
    answered.add(safeKey(r.cal.key));
    for (const ev of r.items) {
      const doc = eventDoc(ev, r.cal);
      if (doc) fresh.set(eventDocId(r.cal.key, ev.id), { doc, sig: signature(doc) });
    }
  }
  const listedKeys = new Set(cals.map((c) => safeKey(c.key)));

  // What's stored now: doc id → { sig, start, end }.
  let stored;
  if (full || range) {
    const snap = await userDoc(uid).collection("events")
      .where("start", ">=", Timestamp.fromMillis(window.from))
      .where("start", "<", Timestamp.fromMillis(window.to))
      .get();
    stored = new Map(snap.docs.filter((d) => d.data().account === email)
      .map((d) => [d.id, { sig: signature(d.data()), start: millis(d.data().start), end: millis(d.data().end) }]));
  } else {
    stored = new Map(Object.entries(acct.seen || {}).map(([id, v]) => {
      const [sig, start, end] = v.split("|");
      return [id, { sig, start: Number(start), end: Number(end || start) }];
    }));
  }

  const events = userDoc(uid).collection("events");
  const writes = [];
  const kept = new Set(); // over, so left as they were
  for (const [id, f] of fresh) {
    const old = stored.get(id);
    if (old && old.sig === f.sig) continue;
    const end = millis(f.doc.end);
    if (old && over(old.end)) {
      kept.add(id);
      continue;
    }
    if (!old && over(end)) {
      const cal = calendarOfDocId(id);
      if (pending.has(cal) || end < (skippedBefore[cal] || 0)) continue;
    }
    writes.push((b) => b.set(events.doc(id), { ...f.doc, syncedAt: FieldValue.serverTimestamp() }));
  }
  for (const [id, old] of stored) {
    if (fresh.has(id) || !inWindow(old.start)) continue;
    if (over(old.end)) {
      kept.add(id);
      continue;
    }
    const cal = calendarOfDocId(id);
    // Deleted in Google, or its calendar is gone. A calendar that didn't
    // answer this time keeps its events.
    if (answered.has(cal) || !listedKeys.has(cal)) writes.push((b) => b.delete(events.doc(id)));
  }
  await commit(writes);

  const update = { calendarsSig: calSig, calendarKeys: cals.map((c) => c.key) };
  if (!range) {
    // Remember the window as it is now; events that slide out of it stay in
    // Firestore as they were. Kept events are remembered as stored, not as
    // Google has them now.
    const seen = {};
    for (const [id, f] of fresh) {
      if (!kept.has(id)) seen[id] = `${f.sig}|${millis(f.doc.start)}|${millis(f.doc.end)}`;
    }
    for (const [id, old] of stored) {
      const waiting = !fresh.has(id) && !answered.has(calendarOfDocId(id)) && listedKeys.has(calendarOfDocId(id));
      if ((kept.has(id) || waiting) && inWindow(old.start)) seen[id] = `${old.sig}|${old.start}|${old.end}`;
    }
    update.seen = seen;
  }
  // Say when it last synced, without a write every single minute.
  const error = errors.length ? errors.join("\n") : null;
  const statusAt = millis(acct.statusAt) || 0;
  if (writes.length || full || error !== (acct.lastError || null) || now - statusAt > 10 * 60 * 1000) {
    await setLink(uid, email, { linked: true, error, lastSync: FieldValue.serverTimestamp() });
    update.statusAt = Timestamp.now();
    update.lastError = error;
  }
  if (!range || update.statusAt) await ref.update(update);
  return { email, changed: writes.length, errors };
}

// ---------------------------------------------------------------- callable from the app

function requireUid(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  return request.auth.uid;
}

async function linkedAccounts(uid) {
  return (await accountsOf(uid).get()).docs.filter((d) => !d.data().revoked);
}

async function accountFor(uid, calendarKey) {
  const email = String(calendarKey || "").split("|")[0];
  const snap = await accountsOf(uid).doc(accountId(email)).get();
  if (!snap.exists || snap.data().revoked) {
    throw new HttpsError("failed-precondition", `${email || "That account"} isn't linked. Connect it again in Optimizer on the web.`);
  }
  return snap;
}

const callErrors = (e) => {
  if (e instanceof HttpsError) return e;
  logger.warn("google call failed", { message: e.message, status: e.status });
  return new HttpsError("failed-precondition", e.message);
};

const withSecret = { secrets: [CLIENT_SECRET], timeoutSeconds: 120 };

/** Finishes linking a Google account: [code] is what Google's sign-in popup handed the app. */
exports.linkGoogleAccount = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const code = String((request.data && request.data.code) || "");
  if (!code) throw new HttpsError("invalid-argument", "Google didn't hand over a sign-in code.");
  // The page Google sent you back to (the redirect flow), or "postmessage"
  // for codes from the old pop-up. Google checks it matches the one the code
  // was issued for.
  const redirectUri = String((request.data && request.data.redirectUri) || "postmessage");
  if (redirectUri !== "postmessage" && !/^https?:\/\/[^/]+\/$/.test(redirectUri)) {
    throw new HttpsError("invalid-argument", "That isn't a page Optimizer sends you back to.");
  }
  try {
    const t = await tokenRequest({ grant_type: "authorization_code", code, redirect_uri: redirectUri });
    if (!String(t.scope || "").split(" ").includes(SCOPE)) {
      throw new HttpsError("permission-denied", "Calendar access wasn't allowed. Try again and tick the calendar box.");
    }
    // The primary calendar's id is the account's email address.
    const primary = (await listAll(t.access_token, "users/me/calendarList", { maxResults: "250" })).find((c) => c.primary);
    const email = primary && primary.id;
    if (!email) throw new HttpsError("failed-precondition", "That Google account has no calendar.");

    const ref = accountsOf(uid).doc(accountId(email));
    const before = await ref.get();
    const refreshToken = t.refresh_token || (before.exists && !before.data().revoked ? before.data().refreshToken : null);
    if (!refreshToken) {
      // Google only hands out a lasting sign-in when it asks you to allow
      // access. Letting go of this one makes it ask next time.
      await fetch(`https://oauth2.googleapis.com/revoke?token=${enc(t.access_token)}`, { method: "POST" }).catch(() => {});
      throw new HttpsError("failed-precondition", "Google needs you to allow access once more. Click Connect again.");
    }
    await ref.set({ email, refreshToken, linkedAt: FieldValue.serverTimestamp(), revoked: false, seen: {}, calendarsSig: null, calendarKeys: [] });
    accessTokens.set(`${uid}|${email}`, { token: t.access_token, refreshToken, expires: Date.now() + (t.expires_in || 3600) * 1000 });
    const r = await syncAccount(uid, ref, { email, refreshToken, calendarKeys: [] }, { full: true });
    return { email, changed: r.changed, errors: r.errors };
  } catch (e) {
    throw callErrors(e);
  }
});

/** Checks every linked account now (the Sync button). [from]/[to] (ms) also sync a far-off span. */
exports.syncGoogleNow = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const from = Number(request.data && request.data.from) || null;
  const to = Number(request.data && request.data.to) || null;
  const range = from && to && to > from && to - from <= 400 * DAY ? { from, to } : null;
  const errors = [];
  let changed = 0;
  await Promise.all((await linkedAccounts(uid)).map(async (d) => {
    try {
      const r = await syncAccount(uid, d.ref, d.data(), range ? { range } : { full: true });
      changed += r.changed;
      errors.push(...r.errors.map((m) => `${d.data().email} · ${m}`));
    } catch (e) {
      errors.push(`${d.data().email}: ${e.message}`);
    }
  }));
  return { changed, errors };
});

exports.unlinkGoogleAccount = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const email = String((request.data && request.data.email) || "");
  if (!email) throw new HttpsError("invalid-argument", "Which account?");
  const ref = accountsOf(uid).doc(accountId(email));
  const snap = await ref.get();
  if (snap.exists && snap.data().refreshToken && !snap.data().revoked) {
    await fetch(`https://oauth2.googleapis.com/revoke?token=${enc(snap.data().refreshToken)}`, { method: "POST" }).catch(() => {});
  }
  await ref.delete();
  accessTokens.delete(`${uid}|${email}`);
  const events = await userDoc(uid).collection("events").where("account", "==", email).get();
  await commit(events.docs.map((d) => (b) => b.delete(d.ref)));
  await db.runTransaction(async (tx) => {
    const s = await tx.get(userDoc(uid));
    if (!s.exists) return;
    const d = s.data();
    tx.update(userDoc(uid),
      "accounts", (d.accounts || []).filter((a) => a !== email),
      "calendars", (d.calendars || []).filter((c) => c && c.account !== email),
      new FieldPath("googleLinks", email), FieldValue.delete());
  });
  return { removed: events.size };
});

/**
 * Your answer for a new calendar's past events (keepPast): [keep] saves its
 * past year now; otherwise its events from before now are never saved.
 */
exports.resolvePastEvents = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const calendarKey = String((request.data && request.data.calendarKey) || "");
  const keep = !!(request.data && request.data.keep);
  if (!calendarKey) throw new HttpsError("invalid-argument", "Which calendar?");
  const now = Date.now();
  let saved = 0;
  if (keep) {
    try {
      const acct = await accountFor(uid, calendarKey);
      const token = await accessToken(uid, acct.data());
      const settings = (await userDoc(uid).get()).data() || {};
      const cal = (settings.calendars || []).find((c) => c && safeKey(c.key) === calendarKey);
      if (cal) {
        const items = await listAll(token, `calendars/${enc(cal.id)}/events`, {
          timeMin: new Date(now - 365 * DAY).toISOString(),
          timeMax: new Date(now).toISOString(),
          singleEvents: "true",
          maxResults: "2500",
        });
        const events = userDoc(uid).collection("events");
        const writes = [];
        for (const ev of items) {
          const doc = eventDoc(ev, cal);
          if (doc && millis(doc.end) <= now) writes.push((b) => b.set(events.doc(eventDocId(cal.key, ev.id)), { ...doc, syncedAt: FieldValue.serverTimestamp() }));
        }
        await commit(writes);
        saved = writes.length;
      }
    } catch (e) {
      throw callErrors(e);
    }
  }
  await userDoc(uid).set({
    pastPending: FieldValue.arrayRemove(calendarKey),
    ...(keep ? {} : { pastSkippedBefore: { [calendarKey]: now } }),
  }, { merge: true });
  return { saved };
});

/** Writes an event Google just returned into Firestore, so it shows at once. */
async function storeEvent(uid, calendarKey, ev) {
  const settings = (await userDoc(uid).get()).data() || {};
  const cal = (settings.calendars || []).find((c) => c && c.key === calendarKey);
  const doc = cal && eventDoc(ev, cal);
  if (doc) await userDoc(uid).collection("events").doc(eventDocId(calendarKey, ev.id)).set({ ...doc, syncedAt: FieldValue.serverTimestamp() });
}

/**
 * Creates (no [eventId]) or changes an event. [moveFrom] is the event's old
 * calendar when it's being moved: it's created in the new one and deleted there.
 */
exports.saveGoogleEvent = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const { calendarKey, eventId, body, moveFrom } = request.data || {};
  if (!calendarKey || !body || typeof body !== "object") throw new HttpsError("invalid-argument", "Nothing to save.");
  try {
    const acct = await accountFor(uid, calendarKey);
    const token = await accessToken(uid, acct.data());
    const calId = String(calendarKey).slice(String(calendarKey).indexOf("|") + 1);
    const saved = eventId
      ? await google(token, "PATCH", `calendars/${enc(calId)}/events/${enc(eventId)}`, { body })
      : await google(token, "POST", `calendars/${enc(calId)}/events`, { body });
    await storeEvent(uid, calendarKey, saved);
    if (moveFrom && moveFrom.calendarKey && moveFrom.eventId) {
      await deleteEvent(uid, moveFrom.calendarKey, moveFrom.eventId);
    }
    return { id: saved.id };
  } catch (e) {
    throw callErrors(e);
  }
});

async function deleteEvent(uid, calendarKey, eventId) {
  const acct = await accountFor(uid, calendarKey);
  const token = await accessToken(uid, acct.data());
  const calId = String(calendarKey).slice(String(calendarKey).indexOf("|") + 1);
  await google(token, "DELETE", `calendars/${enc(calId)}/events/${enc(eventId)}`);
  await userDoc(uid).collection("events").doc(eventDocId(calendarKey, eventId)).delete();
}

exports.deleteGoogleEvent = onCall(withSecret, async (request) => {
  const uid = requireUid(request);
  const { calendarKey, eventId } = request.data || {};
  if (!calendarKey || !eventId) throw new HttpsError("invalid-argument", "Which event?");
  try {
    await deleteEvent(uid, calendarKey, eventId);
    return { deleted: true };
  } catch (e) {
    throw callErrors(e);
  }
});

// ---------------------------------------------------------------- every minute

exports.pollGoogleCalendars = onSchedule(
  { schedule: "every 1 minutes", timeoutSeconds: 55, memory: "256MiB", retryCount: 0, maxInstances: 1, secrets: [CLIENT_SECRET] },
  async () => {
    const accounts = (await db.collectionGroup("googleAccounts").get()).docs
      .filter((d) => d.ref.parent.parent && d.ref.parent.parent.parent.id === "optimizerSecrets" && !d.data().revoked);
    // Skip anyone who turned auto-sync off.
    const uids = [...new Set(accounts.map((d) => d.ref.parent.parent.id))];
    const settings = new Map();
    await Promise.all(uids.map(async (uid) => settings.set(uid, (await userDoc(uid).get()).data() || {})));
    await mapLimit(accounts.filter((d) => settings.get(d.ref.parent.parent.id).autoSync !== false), 5, async (d) => {
      try {
        await syncAccount(d.ref.parent.parent.id, d.ref, d.data(), { settings: settings.get(d.ref.parent.parent.id) });
      } catch (e) {
        logger.info("google sync failed", { account: d.ref.path, message: e.message });
      }
    });
  },
);
