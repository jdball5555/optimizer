// Console integration: lets Console, Axis Optic's developer app (Firebase
// project axis-optic-ce4f2), see and manage Optimizer, the same way it does
// Scorecards.
//
//   optimizerConsoleNewUser  someone opens Optimizer for the first time
//                            (optimizerPeople/{uid} created) -> "new user"
//                            alert
//   optimizerConsoleAdmin    Console's user admin: list users, view a user,
//                            change their settings (name, email, sign-in,
//                            premium beta)
//
// Optimizer shares its Firebase project, and so its sign-ins, with Asset
// Track and Axis Journal. Optimizer's users are the accounts in
// optimizerPeople (everyone who has opened it), not every account in the
// project. Name, email and blocking sign-in change the shared account, so
// they apply to all three apps; Console's hints say so.
//
// Both directions use Google-signed identity tokens from each project's Cloud
// Functions service account, so there are no secrets to set up:
//   this project -> reportAppEvent (axis-optic-ce4f2)
//   axis-optic-ce4f2's consoleService -> optimizerConsoleAdmin (here)
// The names start with "optimizer" because function names are shared with
// Asset Track's codebase in this project.

const functions = require("firebase-functions/v1");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const { OAuth2Client } = require("google-auth-library");
const { userHasPremiumBeta, setPremiumBeta } = require("./premium");

const db = getFirestore();
const auth = getAuth();
const oidc = new OAuth2Client();

const REPORT_EVENT_URL =
  "https://us-central1-axis-optic-ce4f2.cloudfunctions.net/reportAppEvent";
const ADMIN_URL = "https://us-central1-project-axis-app.cloudfunctions.net/optimizerConsoleAdmin";

// Axis Optic's Cloud Functions accounts (where Console's consoleService runs).
// The first is "<Axis Optic's project number>-compute@developer.gserviceaccount.com"
// (Firebase console → Project settings → Project number).
const CONSOLE_SERVICE_ACCOUNTS = [
  "139844049918-compute@developer.gserviceaccount.com",
  "axis-optic-ce4f2@appspot.gserviceaccount.com",
];

// ---------------------------------------------------------------------------
// APP: what Console shows and can change for an Optimizer user.
// ---------------------------------------------------------------------------
const APP_COLOR = "#4D6BFF";
const SHARED = "Shared with Asset Track and Axis Journal, so it changes there too.";

const PREMIUM_BETA_NOTE =
  "Early features for this account. Right now: Net worth (its page and the money panels on Home) " +
  "and the assistant (its panel, the Ask page and its settings). " +
  "They see a small \"Premium beta\" note under their account in Settings.";

const people = db.collection("optimizerPeople");
const mine = (uid) => db.collection("optimizer").doc(uid);

function providerLabel(id) {
  return { password: "Email", "google.com": "Google", "apple.com": "Apple" }[id] || id;
}

function iso(v) {
  if (!v) return null;
  if (typeof v.toDate === "function") return v.toDate().toISOString();
  const d = new Date(v);
  return isNaN(d) ? null : d.toISOString();
}

async function count(query) {
  try {
    return (await query.count().get()).data().count;
  } catch (_) {
    return null;
  }
}

/** Auth records for these uids (missing ones left out), 100 at a time. */
async function authUsers(uids) {
  const out = new Map();
  for (let i = 0; i < uids.length; i += 100) {
    const r = await auth.getUsers(uids.slice(i, i + 100).map((uid) => ({ uid })));
    for (const u of r.users) out.set(u.uid, u);
  }
  return out;
}

/** Optimizer's users: optimizerPeople, with their Auth records. */
async function optimizerUsers() {
  const docs = (await people.get()).docs;
  const byUid = await authUsers(docs.map((d) => d.id));
  return docs.filter((d) => byUid.has(d.id)).map((d) => ({ doc: d, u: byUid.get(d.id) }));
}

function listEntry({ doc, u }) {
  const d = doc.data() || {};
  return {
    uid: u.uid,
    name: d.name || u.displayName || "",
    email: u.email || d.email || "",
    // When they first opened Optimizer (the account may be older, from Asset Track).
    created: iso(doc.createTime) || iso(u.metadata.creationTime),
    lastActive: iso(u.metadata.lastRefreshTime || u.metadata.lastSignInTime),
    disabled: u.disabled,
    tags: [
      ...u.providerData.map((p) => providerLabel(p.providerId)),
      ...(userHasPremiumBeta(u) ? ["Premium beta"] : []),
    ],
  };
}

const actions = {
  async summary() {
    const users = await optimizerUsers();
    const weekAgo = Date.now() - 7 * 24 * 3600 * 1000;
    const newThisWeek = users.filter(({ doc }) => doc.createTime && doc.createTime.toMillis() > weekAgo).length;
    return {
      stats: [
        { label: "Users", value: users.length },
        { label: "New this week", value: newThisWeek },
        { label: "Premium beta", value: users.filter(({ u }) => userHasPremiumBeta(u)).length },
        { label: "Canvas feeds", value: await count(db.collectionGroup("canvasFeeds")) },
        { label: "Google accounts", value: await count(db.collectionGroup("googleAccounts")) },
      ],
    };
  },

  async listUsers() {
    const users = (await optimizerUsers()).map(listEntry);
    users.sort((a, b) => String(b.created).localeCompare(String(a.created)));
    return { users };
  },

  async getUser({ uid }) {
    if (!uid) throw httpError(400, "uid is required");
    let u;
    try {
      u = await auth.getUser(uid);
    } catch (e) {
      throw httpError(404, "That user doesn't exist anymore.");
    }
    const doc = await people.doc(uid).get();
    if (!doc.exists) throw httpError(404, "That account hasn't used Optimizer.");
    const entry = listEntry({ doc, u });
    const day = new Date().toISOString().slice(0, 10);

    const [feeds, google, trips, devices, usage] = await Promise.all([
      count(db.collection("axisCalendar").doc(uid).collection("canvasFeeds")),
      count(db.collection("optimizerSecrets").doc(uid).collection("googleAccounts")),
      count(mine(uid).collection("trips")),
      count(db.collection("axisCalendar").doc(uid).collection("devices")),
      mine(uid).collection("aiUsage").doc(day).get().catch(() => null),
    ]);
    const n = (v) => (v == null ? "—" : String(v));
    const aiToday = usage && usage.exists ? Number(usage.get("calls")) || 0 : 0;

    return {
      user: entry,
      sections: [
        {
          title: "Account",
          fields: [
            { key: "displayName", type: "text", label: "Display name", value: entry.name, hint: SHARED },
            { key: "email", type: "text", label: "Email", value: entry.email, hint: `Their sign-in email. ${SHARED}` },
            {
              key: "disabled",
              type: "bool",
              label: "Block sign-in",
              value: u.disabled,
              hint: "Disables the account and signs them out everywhere: Optimizer, Asset Track and Axis Journal.",
              danger: true,
            },
            { type: "info", label: "Signs in with", value: u.providerData.map((p) => providerLabel(p.providerId)).join(", ") || "—" },
            { type: "info", label: "On Optimizer since", value: entry.created, format: "date" },
            { type: "info", label: "Axis account since", value: iso(u.metadata.creationTime), format: "date" },
            { type: "info", label: "Last active", value: entry.lastActive, format: "date" },
            { type: "info", label: "User ID", value: uid, copy: true },
          ],
        },
        {
          title: "Premium beta",
          note: PREMIUM_BETA_NOTE,
          fields: [{ key: "premiumBeta", type: "bool", label: "Premium beta", value: userHasPremiumBeta(u) }],
        },
        {
          title: "Activity",
          fields: [
            { type: "info", label: "Canvas feeds", value: n(feeds) },
            { type: "info", label: "Google accounts linked", value: n(google) },
            { type: "info", label: "Trips", value: n(trips) },
            { type: "info", label: "Devices with notifications", value: n(devices) },
            { type: "info", label: "Assistant calls today", value: String(aiToday) },
          ],
        },
      ],
      actions: [
        {
          id: "revoke_sessions",
          label: "Sign out everywhere",
          icon: "logout",
          confirm: "They'll have to sign in again on every device, in Optimizer, Asset Track and Axis Journal.",
        },
        ...(u.providerData.some((p) => p.providerId === "password")
          ? [{ id: "password_reset_link", label: "Get a password reset link", icon: "key" }]
          : []),
      ],
    };
  },

  async updateUser({ uid, changes, by }) {
    if (!uid || !changes || typeof changes !== "object") throw httpError(400, "uid and changes are required");
    const authUpdate = {};
    const peopleUpdate = {};
    let premiumBeta;
    for (const [key, value] of Object.entries(changes)) {
      if (key === "displayName") {
        const name = String(value || "").trim().slice(0, 80);
        authUpdate.displayName = name || null;
        if (name) peopleUpdate.name = name;
      } else if (key === "email") {
        const email = String(value || "").trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw httpError(400, "That isn't an email address.");
        authUpdate.email = email;
        peopleUpdate.email = email;
      } else if (key === "disabled") {
        authUpdate.disabled = value === true;
      } else if (key === "premiumBeta") {
        premiumBeta = value === true;
      } else {
        throw httpError(400, `Unknown setting "${key}".`);
      }
    }
    try {
      if (Object.keys(authUpdate).length) await auth.updateUser(uid, authUpdate);
    } catch (e) {
      if (e.code === "auth/email-already-exists") throw httpError(400, "Another account already uses that email.");
      if (e.code === "auth/user-not-found") throw httpError(404, "That user doesn't exist anymore.");
      throw e;
    }
    if (authUpdate.disabled === true) await auth.revokeRefreshTokens(uid);
    if (premiumBeta !== undefined) await setPremiumBeta(uid, premiumBeta);
    if (Object.keys(peopleUpdate).length) await people.doc(uid).set(peopleUpdate, { merge: true });
    functions.logger.info(`Console (${by}) updated ${uid}`, Object.keys(changes));
    return { ok: true };
  },

  async userAction({ uid, id, by }) {
    if (!uid || !id) throw httpError(400, "uid and id are required");
    functions.logger.info(`Console (${by}) ran ${id} on ${uid}`);
    if (id === "revoke_sessions") {
      await auth.revokeRefreshTokens(uid);
      return { message: "Signed out on every device." };
    }
    if (id === "password_reset_link") {
      const u = await auth.getUser(uid);
      if (!u.email) throw httpError(400, "They have no email.");
      const link = await auth.generatePasswordResetLink(u.email);
      return { message: "Reset link copied. Send it to them.", copy: link };
    }
    throw httpError(400, `Unknown action "${id}".`);
  },
};

// ---------------------------------------------------------------------------
// Plumbing (same as Scorecards' console.js).
// ---------------------------------------------------------------------------
function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}

/** A Google identity token from this function's service account, for `audience`. */
async function googleIdentityToken(audience) {
  const url =
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity" +
    `?format=full&audience=${encodeURIComponent(audience)}`;
  const r = await fetch(url, { headers: { "Metadata-Flavor": "Google" } });
  if (!r.ok) throw new Error(`metadata identity token: HTTP ${r.status}`);
  return r.text();
}

/** Sends an alert to Console (it decides whether to push it, per its Alerts settings). */
async function reportToConsole(event, { title, body, data = {} }) {
  try {
    const token = await googleIdentityToken(REPORT_EVENT_URL);
    const res = await fetch(REPORT_EVENT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ event, title, body, data, color: APP_COLOR }),
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) functions.logger.warn(`Console event ${event}: HTTP ${res.status}`, await res.text());
  } catch (e) {
    functions.logger.warn(`Console event ${event} not sent`, e);
  }
}

// Someone opened Optimizer for the first time (registerMe in people.js).
exports.optimizerConsoleNewUser = functions.firestore.document("optimizerPeople/{uid}").onCreate(async (snap, context) => {
  const d = snap.data() || {};
  let how = "";
  try {
    const u = await auth.getUser(context.params.uid);
    how = u.providerData.map((p) => providerLabel(p.providerId)).join(", ");
  } catch (_) {}
  const who = d.name || d.email || "Someone";
  await reportToConsole("new_user", {
    title: "⚡ New Optimizer user",
    body: `${who}${d.name && d.email ? ` (${d.email})` : ""}${how ? ` · ${how}` : ""}`,
    data: { uid: context.params.uid },
  });
});

// Only Axis Team's functions may call this (Cloud IAM), on top of the token
// check below.
exports.optimizerConsoleAdmin = functions.runWith({ invoker: CONSOLE_SERVICE_ACCOUNTS }).https.onRequest(async (req, res) => {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const token = String(req.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  try {
    const ticket = await oidc.verifyIdToken({ idToken: token, audience: ADMIN_URL });
    const p = ticket.getPayload() || {};
    if (!p.email_verified || !CONSOLE_SERVICE_ACCOUNTS.includes(String(p.email).toLowerCase())) {
      throw new Error(`untrusted caller ${p.email || p.sub}`);
    }
  } catch (e) {
    functions.logger.warn("optimizerConsoleAdmin: rejected", e.message);
    return res.status(403).json({ error: "Not allowed" });
  }

  const body = req.body || {};
  const handler = Object.prototype.hasOwnProperty.call(actions, body.action) && actions[body.action];
  if (!handler) return res.status(400).json({ error: `Unknown action "${body.action}"` });
  try {
    return res.status(200).json(await handler(body));
  } catch (e) {
    if (e.status) return res.status(e.status).json({ error: e.message });
    functions.logger.error(`optimizerConsoleAdmin ${body.action} failed`, e);
    return res.status(500).json({ error: "Something went wrong in Optimizer." });
  }
});
