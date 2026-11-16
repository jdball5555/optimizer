// Reads a Canvas calendar feed (an .ics file) into plain items.
//
// Canvas writes one VEVENT per assignment and per calendar event, e.g.
//   UID:event-assignment-123456
//   SUMMARY:Essay 2 [ENGL 101]
//   DTSTART:20261108T045900Z        (assignments: start = end = the due time)
//   DTSTART;VALUE=DATE:20261108     (all-day: for an assignment, due at 11:59 PM, see canvas.dart)
//   URL;VALUE=URI:https://school.instructure.com/...#assignment_123456

/** Lines folded onto the next line (which then starts with a space) are joined back up. */
function unfold(text) {
  return text.replace(/\r\n?/g, "\n").replace(/\n[ \t]/g, "");
}

/** `NAME;PARAM=V:value` → { name, params, value }. Colons inside quoted params don't split. */
function parseLine(line) {
  let quoted = false;
  let i = 0;
  for (; i < line.length; i++) {
    const c = line[i];
    if (c === '"') quoted = !quoted;
    else if (c === ":" && !quoted) break;
  }
  const head = line.slice(0, i).split(";");
  const params = {};
  for (const p of head.slice(1)) {
    const eq = p.indexOf("=");
    if (eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, "");
  }
  return { name: head[0].toUpperCase(), params, value: line.slice(i + 1) };
}

function unescapeText(v) {
  return v.replace(/\\n/gi, "\n").replace(/\\([,;\\])/g, "$1").trim();
}

/** How far ahead of UTC [tz] is at the instant [ms]. */
function tzOffset(ms, tz) {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - ms;
}

/** A wall-clock time in [tz] → epoch ms. */
function zonedToUtc(y, mo, d, h, mi, s, tz) {
  const wall = Date.UTC(y, mo - 1, d, h, mi, s);
  try {
    const off = tzOffset(wall, tz);
    const off2 = tzOffset(wall - off, tz);
    return wall - off2;
  } catch (_) {
    return wall; // unknown zone: treat as UTC
  }
}

/** DTSTART/DTEND → { allDay, date: 'yyyy-mm-dd' } or { allDay: false, ms }. */
function parseWhen(value, params) {
  const v = value.trim();
  if (params.VALUE === "DATE" || /^\d{8}$/.test(v)) {
    return { allDay: true, date: `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)}` };
  }
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z)?$/.exec(v);
  if (!m) return null;
  const [, y, mo, d, h, mi, s = "00", z] = m;
  const ms = z ? Date.UTC(+y, +mo - 1, +d, +h, +mi, +s) : zonedToUtc(+y, +mo, +d, +h, +mi, +s, params.TZID || "UTC");
  return { allDay: false, ms };
}

function addDay(ymd, n) {
  const t = new Date(`${ymd}T00:00:00Z`);
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}

/** "Essay 2 [ENGL 101]" → { title: "Essay 2", course: "ENGL 101" }. */
function splitCourse(summary) {
  const m = /^(.*?)\s*\[([^\]]+)\]\s*$/.exec(summary);
  return m && m[1] ? { title: m[1], course: m[2] } : { title: summary, course: "" };
}

function kindOf(uid) {
  if (/assignment/i.test(uid)) return "assignment";
  if (/quiz/i.test(uid)) return "assignment";
  return "event";
}

/**
 * The whole feed → { name, items }. Each item:
 *   uid, title, course, kind, task, description, url, location, updated (epoch ms),
 *   allDay + date/endDate (yyyy-mm-dd, end exclusive)  or  start/end (epoch ms)
 */
function parseCalendar(text) {
  if (!/BEGIN:VCALENDAR/.test(text)) throw new Error("not a calendar");
  const lines = unfold(text).split("\n");
  let name = "";
  const items = [];
  let ev = null;
  for (const raw of lines) {
    if (!raw) continue;
    const { name: key, params, value } = parseLine(raw);
    if (key === "BEGIN" && value === "VEVENT") { ev = {}; continue; }
    if (key === "END" && value === "VEVENT") {
      if (ev && ev.uid && ev.start) items.push(finish(ev));
      ev = null;
      continue;
    }
    if (!ev) {
      if (key === "X-WR-CALNAME") name = unescapeText(value);
      continue;
    }
    switch (key) {
      case "UID": ev.uid = value.trim(); break;
      case "SUMMARY": ev.summary = unescapeText(value); break;
      case "DESCRIPTION": ev.description = unescapeText(value); break;
      case "URL": ev.url = value.trim(); break;
      case "LOCATION": ev.location = unescapeText(value); break;
      case "DTSTART": ev.start = parseWhen(value, params); break;
      case "DTEND": ev.end = parseWhen(value, params); break;
      case "STATUS": ev.status = value.trim().toUpperCase(); break;
      case "DTSTAMP": ev.stamp = parseWhen(value, params); break;
    }
  }
  return { name, items: items.filter((i) => i.status !== "CANCELLED") };
}

function finish(ev) {
  const { title, course } = splitCourse(ev.summary || "(No title)");
  const kind = kindOf(ev.uid);
  const out = {
    uid: ev.uid,
    title,
    course,
    kind,
    task: kind === "assignment",
    description: (ev.description || "").slice(0, 20000),
    url: ev.url || "",
    location: ev.location || "",
    status: ev.status,
    allDay: ev.start.allDay,
  };
  // When it last changed in Canvas.
  if (ev.stamp && !ev.stamp.allDay) out.updated = ev.stamp.ms;
  if (ev.start.allDay) {
    out.date = ev.start.date;
    out.endDate = ev.end && ev.end.allDay && ev.end.date > ev.start.date ? ev.end.date : addDay(ev.start.date, 1);
  } else {
    out.start = ev.start.ms;
    out.end = ev.end && !ev.end.allDay && ev.end.ms >= ev.start.ms ? ev.end.ms : ev.start.ms;
  }
  return out;
}

module.exports = { parseCalendar, splitCourse };
