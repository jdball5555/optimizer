// Turning Google Calendar events into Optimizer's Firestore copy of them.
// Kept apart from google.js so it can be tested without Firebase.

const crypto = require("crypto");
const { Timestamp } = require("firebase-admin/firestore");

const sha = (s) => crypto.createHash("sha1").update(s).digest("hex");

// Google Calendar's fixed event colors (colorId → color), as in calendar_models.dart.
const EVENT_COLORS = {
  1: "#7986CB", 2: "#33B679", 3: "#8E24AA", 4: "#E67C73", 5: "#F6BF26", 6: "#F4511E",
  7: "#039BE5", 8: "#616161", 9: "#3F51B5", 10: "#0B8043", 11: "#D50000",
};

/** Midnight at the start of [ymd] in time zone [tz], as epoch ms. */
function zonedMidnight(ymd, tz) {
  const [y, m, d] = ymd.split("-").map(Number);
  const utc = Date.UTC(y, m - 1, d);
  if (!tz) return utc;
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    }).formatToParts(new Date(utc));
    const get = (t) => Number(parts.find((p) => p.type === t).value);
    const shown = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
    return utc - (shown - utc);
  } catch (_) {
    return utc;
  }
}

function nextDay(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
}

/** The Firestore copy of one Google event (the same fields the app reads), or null if it's cancelled. */
function eventDoc(ev, cal) {
  if (!ev || ev.status === "cancelled" || !ev.start) return null;
  const allDay = !!ev.start.date;
  const doc = {
    calendarKey: cal.key,
    calendarId: cal.id,
    calendarName: cal.name,
    account: cal.account,
    eventId: ev.id,
    title: (ev.summary || "").trim() ? ev.summary : "(No title)",
    description: ev.description || "",
    location: ev.location || "",
    allDay,
    color: EVENT_COLORS[ev.colorId] || cal.color,
    colorId: ev.colorId || null,
    recurring: !!ev.recurringEventId,
    htmlLink: ev.htmlLink || null,
  };
  if (allDay) {
    let endDate = (ev.end && ev.end.date) || nextDay(ev.start.date);
    if (endDate <= ev.start.date) endDate = nextDay(ev.start.date);
    // The days themselves, so every device shows them on the right day
    // whatever its time zone; start/end are for range queries.
    doc.date = ev.start.date;
    doc.endDate = endDate;
    doc.start = Timestamp.fromMillis(zonedMidnight(ev.start.date, cal.timeZone));
    doc.end = Timestamp.fromMillis(zonedMidnight(endDate, cal.timeZone));
  } else {
    const s = Date.parse(ev.start.dateTime);
    let e = ev.end && ev.end.dateTime ? Date.parse(ev.end.dateTime) : s;
    if (!(e > s)) e = s + 15 * 60 * 1000;
    doc.start = Timestamp.fromMillis(s);
    doc.end = Timestamp.fromMillis(e);
  }
  return doc;
}

const millis = (t) => (t && t.toMillis ? t.toMillis() : null);

// Fields that, if unchanged, mean the stored copy needn't be rewritten.
const signature = (d) => sha(JSON.stringify([d.title, millis(d.start), millis(d.end), d.allDay, d.date || null,
  d.location, d.description, d.color, d.colorId || null, d.calendarName, d.htmlLink || null, d.recurring])).slice(0, 12);

module.exports = { eventDoc, signature, millis, zonedMidnight };
