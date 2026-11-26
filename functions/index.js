// Optimizer's Canvas calendar feeds (and, in google.js, the Google Calendar sync).
//
//   axisCalendar/{uid}/canvasFeeds/{feedId}   a feed: its link, name, color, notification settings,
//                                             and `seen` (what each item looked like last check)
//   axisCalendar/{uid}/canvasItems/{itemId}   one assignment or event, shown on the calendar as a task
//   axisCalendar/{uid}/devices/{deviceId}     browsers and phones to notify
//
// With premium beta, pollCanvasFeeds downloads each feed every minute, writes
// what changed and notifies about new assignments and moved due dates. A
// check where nothing changed costs one Firestore read per feed and no
// writes. Without it, feeds are checked only when the app asks
// (refreshCanvasFeeds: on opening and the refresh button), at most five times
// in five minutes (refresh_limit.js), and without notifications.

const crypto = require("crypto");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const { parseCalendar } = require("./ics");
const { notifyUser } = require("./notify");
const { hasPremiumBeta, premiumUids } = require("./premium");
const { takeRefresh, waitText } = require("./refresh_limit");
const { fetchPublic } = require("./safe_fetch");

initializeApp();
const db = getFirestore();

const FEED_COLORS = ["#F97316", "#22C55E", "#A855F7", "#EAB308", "#06B6D4", "#EC4899", "#84CC16"];
const DAY = 24 * 60 * 60 * 1000;

const sha = (s) => crypto.createHash("sha1").update(s).digest("hex");
const userDoc = (uid) => db.collection("axisCalendar").doc(uid);

// ---------------------------------------------------------------- the link

/** A Canvas calendar feed link, cleaned up, or an error saying what's wrong with it. */
function canvasFeedUrl(raw) {
  let s = String(raw || "").trim();
  if (/^webcals?:\/\//i.test(s)) s = "https://" + s.replace(/^webcals?:\/\//i, "");
  let u;
  try {
    u = new URL(s);
  } catch (_) {
    throw new HttpsError("invalid-argument", "That isn't a link. Paste the Calendar Feed link from Canvas.");
  }
  if (u.protocol === "http:") u.protocol = "https:";
  const host = u.hostname.toLowerCase();
  const local = host === "localhost" || host.endsWith(".internal") || host.endsWith(".local") ||
    /^[\d.]+$/.test(host) || host.includes(":");
  if (u.protocol !== "https:" || local || !/^\/feeds\/calendars\/[\w-]+\.ics$/i.test(u.pathname)) {
    throw new HttpsError("invalid-argument",
      "That isn't a Canvas calendar link. In Canvas, open Calendar, click “Calendar Feed” " +
      "(bottom right) and copy that link. It ends in .ics and has /feeds/calendars/ in it.");
  }
  u.hash = "";
  return u.toString();
}

async function download(url) {
  // The stored link is checked again every time, not only when it was added:
  // a Canvas feed link, and (in fetchPublic) https to public addresses only,
  // on every redirect too.
  let link;
  try {
    link = canvasFeedUrl(url);
  } catch (e) {
    throw new Error(e.message);
  }
  let res;
  try {
    res = await fetchPublic(link, {
      headers: { "User-Agent": "Axis Optimizer (calendar feed reader)", "Accept": "text/calendar,*/*" },
      signal: AbortSignal.timeout(20000),
    });
  } catch (e) {
    throw new Error(`Couldn't reach Canvas (${e.name === "TimeoutError" ? "timed out" : e.message})`);
  }
  if (res.status === 404 || res.status === 401 || res.status === 403) {
    throw new Error("Canvas no longer accepts this link (it may have been reset). Copy the Calendar Feed link again.");
  }
  if (!res.ok) throw new Error(`Canvas answered ${res.status}`);
  const text = await res.text();
  if (text.length > 8 * 1024 * 1024) throw new Error("This feed is too big to read");
  try {
    return parseCalendar(text);
  } catch (_) {
    throw new Error("That link didn't return a calendar");
  }
}

// ---------------------------------------------------------------- syncing

/** The item's due time (or day) — a change here is what "due date changed" means. */
const dueOf = (it) => (it.allDay ? it.date : String(it.start));

function dueMs(due) {
  return /^\d{4}-\d{2}-\d{2}$/.test(due) ? Date.parse(`${due}T23:59:59Z`) : Number(due);
}

function itemDoc(it, feedId, isNew) {
  const doc = {
    feedId,
    uid: it.uid,
    title: it.title,
    course: it.course,
    kind: it.kind,
    task: it.task,
    description: it.description,
    url: it.url,
    location: it.location,
    allDay: it.allDay,
    ...(it.updated ? { canvasUpdated: Timestamp.fromMillis(it.updated) } : {}),
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (it.allDay) {
    doc.date = it.date;
    doc.endDate = it.endDate;
    // For range queries: midnight UTC of the day.
    doc.start = Timestamp.fromDate(new Date(`${it.date}T00:00:00Z`));
    doc.end = Timestamp.fromDate(new Date(`${it.endDate}T00:00:00Z`));
  } else {
    doc.start = Timestamp.fromMillis(it.start);
    doc.end = Timestamp.fromMillis(it.end);
  }
  if (isNew) doc.firstSeen = FieldValue.serverTimestamp();
  return doc;
}

/**
 * Brings one feed's items up to date and returns what's worth a notification.
 * [initial] is the first read of a feed: everything is "new", so nothing is announced.
 */
// [touch]: record when it was checked even if nothing changed (asked for
// from the app, which shows when Canvas was last checked).
async function syncFeed(feedRef, feed, { initial = false, downloaded = null, touch = false } = {}) {
  const uid = feedRef.parent.parent.id;
  const items = userDoc(uid).collection("canvasItems");
  const now = Date.now();

  let cal = downloaded;
  try {
    cal = cal || await download(feed.url);
  } catch (e) {
    // Only write when the error is new, so a broken link doesn't cost a write every minute.
    if (feed.lastError !== e.message) {
      await feedRef.update({ lastError: e.message, lastChecked: FieldValue.serverTimestamp() });
    }
    throw e;
  }

  const seen = feed.seen || {};
  const next = {};
  const added = [];
  const moved = [];
  const writes = [];
  for (const it of cal.items) {
    const id = `${feedRef.id}_${sha(it.uid).slice(0, 20)}`;
    const due = dueOf(it);
    const sig = sha(JSON.stringify([it.title, it.course, it.start, it.end, it.date, it.endDate,
      it.url, it.location, it.description, it.updated])).slice(0, 12);
    next[id] = `${sig}|${due}`;
    const old = seen[id];
    if (old === next[id]) continue;
    writes.push((b) => b.set(items.doc(id), itemDoc(it, feedRef.id, old == null), { merge: true }));
    if (initial) continue;
    // Something that turns up already past due isn't news.
    const upcoming = dueMs(due) > now - DAY;
    if (old == null && upcoming) added.push({ ...it, id });
    else if (old != null && old.split("|")[1] !== due && upcoming) moved.push({ ...it, id });
  }
  // Gone from the feed: deleted in Canvas if it was still to come; if it's in
  // the past Canvas just stopped listing it, so keep it (and remember it, so it
  // isn't "new" if it comes back). Forget anything older than half a year.
  for (const [id, v] of Object.entries(seen)) {
    if (id in next) continue;
    const due = dueMs(v.split("|")[1]);
    if (due > now) writes.push((b) => b.delete(items.doc(id)));
    else if (due > now - 180 * DAY) next[id] = v;
  }

  for (let i = 0; i < writes.length; i += 400) {
    const batch = db.batch();
    writes.slice(i, i + 400).forEach((w) => w(batch));
    await batch.commit();
  }

  const lastChecked = feed.lastChecked && feed.lastChecked.toMillis ? feed.lastChecked.toMillis() : 0;
  if (touch || writes.length || feed.lastError || initial || now - lastChecked > 30 * 60 * 1000) {
    await feedRef.update({
      seen: next,
      itemCount: cal.items.length,
      calendarName: cal.name || feed.calendarName || "",
      lastChecked: FieldValue.serverTimestamp(),
      ...(writes.length ? { lastChanged: FieldValue.serverTimestamp() } : {}),
      lastError: null,
    });
  }
  return {
    uid,
    feedName: feed.name || cal.name || "Canvas",
    added: feed.notifyNew === false ? [] : added,
    moved: feed.notifyChanges === false ? [] : moved,
    count: cal.items.length,
  };
}

// ---------------------------------------------------------------- notifications

function whenText(it, tz) {
  if (it.allDay) {
    const day = new Date(`${it.date}T12:00:00Z`).toLocaleDateString("en-US",
      { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
    // Canvas sends just the date for an assignment due at 11:59 PM.
    return it.task ? `${day}, 11:59 PM` : day;
  }
  try {
    return new Date(it.start).toLocaleString("en-US",
      { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: tz });
  } catch (_) {
    return new Date(it.start).toUTCString();
  }
}

/** What to say for one feed's changes, worded for a device in time zone [tz]. */
function messagesFor(r, tz) {
  const out = [];
  const where = (it) => it.course || r.feedName;
  const due = (it) => (it.task ? "due " : "") + whenText(it, tz);
  if (r.added.length > 3) {
    const names = r.added.slice(0, 3).map((it) => it.title).join(", ");
    out.push({
      title: `${r.added.length} new items in Canvas`,
      body: `${names} and ${r.added.length - 3} more`,
      data: { type: "canvas" },
    });
  } else {
    for (const it of r.added) {
      out.push({
        title: `New ${it.task ? "assignment" : "event"} · ${where(it)}`,
        body: `${it.title} — ${due(it)}`,
        data: { type: "canvas", itemId: it.id },
      });
    }
  }
  for (const it of r.moved.slice(0, 5)) {
    out.push({
      title: `${it.task ? "Due date" : "Time"} changed · ${where(it)}`,
      body: `${it.title} — now ${due(it)}`,
      data: { type: "canvas", itemId: it.id },
    });
  }
  return out;
}

async function announce(result) {
  if (!result.added.length && !result.moved.length) return;
  await notifyUser(result.uid, (tz) => messagesFor(result, tz));
}

// ---------------------------------------------------------------- callable from the app

function requireUid(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  return request.auth.uid;
}

exports.addCanvasFeed = onCall(async (request) => {
  const uid = requireUid(request);
  const url = canvasFeedUrl(request.data && request.data.url);
  const feeds = userDoc(uid).collection("canvasFeeds");
  const existing = await feeds.get();
  if (existing.docs.some((d) => d.data().url === url)) {
    throw new HttpsError("already-exists", "That Canvas calendar is already added.");
  }
  let cal;
  try {
    cal = await download(url);
  } catch (e) {
    throw new HttpsError("failed-precondition", e.message);
  }
  const ref = feeds.doc();
  const feed = {
    url,
    name: String((request.data && request.data.name) || "").trim().slice(0, 80) ||
      (cal.name || "Canvas").replace(/\s*\(Canvas\)\s*$/i, "").replace(/\s+Calendar$/i, "") || "Canvas",
    calendarName: cal.name || "",
    color: FEED_COLORS[existing.size % FEED_COLORS.length],
    notifyNew: request.data && request.data.notifyNew !== false,
    notifyChanges: request.data && request.data.notifyChanges !== false,
    createdAt: FieldValue.serverTimestamp(),
    seen: {},
  };
  await ref.set(feed);
  const result = await syncFeed(ref, { ...feed, lastChecked: null }, { initial: true, downloaded: cal });
  return { id: ref.id, name: feed.name, count: result.count };
});

exports.refreshCanvasFeeds = onCall(async (request) => {
  const uid = requireUid(request);
  // At most five in five minutes, counted where only the server can write
  // (optimizerSecrets has no rules for the app), so it can't be reset.
  const limits = db.collection("optimizerSecrets").doc(uid);
  const now = Date.now();
  const verdict = await db.runTransaction(async (tx) => {
    const snap = await tx.get(limits);
    const r = takeRefresh(snap.exists ? snap.data().canvasRefreshes : null, now);
    if (r.ok) tx.set(limits, { canvasRefreshes: r.times }, { merge: true });
    return r;
  });
  if (!verdict.ok) {
    throw new HttpsError("resource-exhausted", waitText(verdict.retryAt, now), { retryAt: verdict.retryAt });
  }

  // Notifications are premium beta's, like the every-minute check.
  const notify = hasPremiumBeta(request.auth);
  const feeds = userDoc(uid).collection("canvasFeeds");
  const docs = request.data && request.data.id ? [await feeds.doc(String(request.data.id)).get()] : (await feeds.get()).docs;
  const errors = [];
  for (const d of docs) {
    if (!d.exists) continue;
    try {
      const result = await syncFeed(d.ref, d.data(), { touch: true });
      if (notify) await announce(result);
    } catch (e) {
      errors.push(`${d.data().name}: ${e.message}`);
    }
  }
  return { checked: docs.length, errors, checkedAt: Date.now() };
});

exports.removeCanvasFeed = onCall(async (request) => {
  const uid = requireUid(request);
  const id = String((request.data && request.data.id) || "");
  if (!id) throw new HttpsError("invalid-argument", "Which feed?");
  const items = await userDoc(uid).collection("canvasItems").where("feedId", "==", id).get();
  for (let i = 0; i < items.docs.length; i += 400) {
    const batch = db.batch();
    items.docs.slice(i, i + 400).forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  await userDoc(uid).collection("canvasFeeds").doc(id).delete();
  return { removed: items.size };
});

exports.sendTestNotification = onCall(async (request) => {
  const uid = requireUid(request);
  // An optional wait, so the phone can be put away and the notification
  // arrives the way a real one does (Android hides pushes for the open app).
  const wait = Math.min(Math.max(Number((request.data && request.data.delaySeconds) || 0), 0), 30);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait * 1000));
  const sent = await notifyUser(uid, () => [{
    title: "New assignment · Test",
    body: "Notifications from Optimizer are working.",
    data: { type: "test" },
  }]);
  return { sent };
});

// ---------------------------------------------------------------- every minute

exports.pollCanvasFeeds = onSchedule(
  { schedule: "every 1 minutes", timeoutSeconds: 55, memory: "256MiB", retryCount: 0, maxInstances: 1 },
  async () => {
    const all = (await db.collectionGroup("canvasFeeds").get()).docs
      .filter((d) => d.ref.parent.parent && d.ref.parent.parent.parent.id === "axisCalendar");
    // Only premium beta's feeds: everyone else's are checked when they ask.
    const premium = await premiumUids([...new Set(all.map((d) => d.ref.parent.parent.id))]);
    const feeds = all.filter((d) => premium.has(d.ref.parent.parent.id));
    let i = 0;
    const worker = async () => {
      while (i < feeds.length) {
        const d = feeds[i++];
        try {
          await announce(await syncFeed(d.ref, d.data()));
        } catch (e) {
          logger.info("feed check failed", { feed: d.ref.path, message: e.message });
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(5, feeds.length) }, worker));
  },
);

// ---------------------------------------------------------------- focus time

// While a focus session with a goal is running, the app keeps
// optimizer/{uid}.focusAlert set to when the goal is reached (and clears it on
// pause or end). This sends the "goal reached" notification then, even with
// the app closed.
exports.pollFocusAlerts = onSchedule(
  { schedule: "every 1 minutes", timeoutSeconds: 50, memory: "256MiB", retryCount: 0, maxInstances: 1 },
  async () => {
    const due = await db.collection("optimizer").where("focusAlert.at", "<=", Timestamp.now()).get();
    for (const d of due.docs) {
      const a = d.data().focusAlert || {};
      // Cleared first, so it's only ever sent once.
      await d.ref.update({ focusAlert: null });
      const what = a.title ? ` on ${a.title}` : "";
      try {
        await notifyUser(d.id, () => [{
          title: "Focus goal reached",
          body: `${a.minutes ? `${a.minutes} min` : "Your session"} of focus${what}. Keep going, or take a break.`,
          data: { type: "focus", session: String(a.session || "") },
        }]);
      } catch (e) {
        logger.warn("focus alert failed", { uid: d.id, message: e.message });
      }
    }
  },
);

// ---------------------------------------------------------------- Google Calendar

Object.assign(exports, require("./google"));

// ---------------------------------------------------------------- people: invitations and groups

Object.assign(exports, require("./people"));

// ---------------------------------------------------------------- trips: flights and commutes

Object.assign(exports, require("./trips"));

// ---------------------------------------------------------------- address suggestions

Object.assign(exports, require("./places"));

// ---------------------------------------------------------------- the built-in assistant (Gemini)

Object.assign(exports, require("./assistant"));

// ---------------------------------------------------------------- Console (Axis Optic's developer app): users and premium beta

Object.assign(exports, require("./console"));
