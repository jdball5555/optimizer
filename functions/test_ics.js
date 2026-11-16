// node test_ics.js — checks the feed reader on a sample shaped like Canvas's.
const assert = require("assert");
const { parseCalendar } = require("./ics");

const sample = [
  "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Instructure//Canvas", "X-WR-CALNAME:Jane Doe Calendar (Canvas)",
  "BEGIN:VEVENT", "DTEND:20261108T045900Z", "DTSTART:20261108T045900Z", "DTSTAMP:20261101T120000Z", "UID:event-assignment-123456",
  "SUMMARY:Essay 2: Argument [ENGL 101-02]",
  "DESCRIPTION:Write 1200 words\\, double spaced.\\nSubmit as PDF.",
  "URL;VALUE=URI:https://school.instructure.com/calendar?include_contexts=course_1#assignment_123456",
  "END:VEVENT",
  "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261110", "DTEND;VALUE=DATE:20261111", "UID:event-calendar-event-77",
  "SUMMARY:No class [BIO 110]", "END:VEVENT",
  // Canvas's own shape for an assignment due at 11:59 PM: just a date, no DTEND.
  "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261115", "UID:event-assignment-999",
  "SUMMARY:Lab 4 [BIO 110]", "END:VEVENT",
  // A section's own due date: the UID changes, the link still names the assignment.
  "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261116", "UID:event-assignment-override-5",
  "SUMMARY:Lab 5 (Section 2) [BIO 110]", "END:VEVENT",
  "BEGIN:VEVENT", "DTSTART:20261201T150000Z", "DTEND:20261201T160000Z", "UID:event-calendar-event-90",
  "LOCATION:Science Hall 102\\, Springfield", "SUMMARY:Office hours [BIO 110]", "END:VEVENT",
  "BEGIN:VEVENT", "DTSTART;TZID=America/Chicago:20261112T140000", "DTEND;TZID=America/Chicago:20261112T153", "0",
  "UID:event-calendar-event-78", "SUMMARY:Midterm review session with a very long name that folds",
  "  onto the next line [BIO 110]", "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n").replace("153\r\n0", "153\r\n 0");

const cal = parseCalendar(sample);
assert.strictEqual(cal.name, "Jane Doe Calendar (Canvas)");
assert.strictEqual(cal.items.length, 6);
const [a, b, lab, override, hours, c] = cal.items;
assert.strictEqual(a.updated, Date.UTC(2026, 10, 1, 12));
assert.deepStrictEqual([lab.allDay, lab.date, lab.endDate, lab.task], [true, "2026-11-15", "2026-11-16", true]);
assert.deepStrictEqual([override.title, override.task], ["Lab 5 (Section 2)", true]);
assert.strictEqual(hours.location, "Science Hall 102, Springfield");
assert.deepStrictEqual([a.title, a.course, a.kind, a.task, a.allDay], ["Essay 2: Argument", "ENGL 101-02", "assignment", true, false]);
assert.strictEqual(new Date(a.start).toISOString(), "2026-11-08T04:59:00.000Z");
assert.strictEqual(a.start, a.end);
assert.strictEqual(a.description, "Write 1200 words, double spaced.\nSubmit as PDF.");
assert.ok(a.url.endsWith("#assignment_123456"));
assert.deepStrictEqual([b.allDay, b.date, b.endDate, b.task], [true, "2026-11-10", "2026-11-11", false]);
assert.strictEqual(c.title, "Midterm review session with a very long name that folds onto the next line");
assert.strictEqual(new Date(c.start).toISOString(), "2026-11-12T20:00:00.000Z"); // 2pm CST = 20:00Z
assert.strictEqual(new Date(c.end).toISOString(), "2026-11-12T21:30:00.000Z");
console.log("ics ok");
