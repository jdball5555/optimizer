// Optimizer's people: invitations to events and to groups, between Optimizer
// accounts, and by link for anyone not on it yet (you send them their link;
// email from Optimizer is ready in email.js for when it's set up).
//
// The truth, server-only (no security rule lets an app touch it):
//   optimizerPeople/{uid}         who's on Optimizer: email, name
//   optimizerInvites/{id}         one person invited to one event or group
//   optimizerEvents/{id}          an event with guests: its owner, details, who can see the guest list
//   optimizerGroups/{id}          a group: owner and name (members are its invitations)
//   optimizerTripShares/{id}      a shared trip: its owner (the people are its invitations, each with a role)
//
// Each person's own copies, which their app reads (optimizer/{uid}/… is theirs):
//   optimizer/{uid}/invites/{inviteId}    invitations to you, with the event's guests if you may see them
//   optimizer/{uid}/sentEvents/{eventId}  your events' guest lists, by event key
//   optimizer/{uid}/groups/{groupId}      groups you own or belong to, with their members
//   optimizer/{uid}/tripPeople/{tripId}   who your trip is shared with
//   optimizer/{uid}/sharedTrips/{shareId} a trip shared with you: only the entries you may see
//
// Everything changes through the functions below, which rewrite the copies.

const crypto = require("crypto");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { notifyUser } = require("./notify");
const { ROLES, roleOnItem, tripCopyFor, cleanSharedItem, cleanTripFields } = require("./trip_share_core");

const db = getFirestore();
const SITE = "https://optimizer.axisoptic.com";

const people = db.collection("optimizerPeople");
const invites = db.collection("optimizerInvites");
const eventsCol = db.collection("optimizerEvents");
const groupsCol = db.collection("optimizerGroups");
const sharesCol = db.collection("optimizerTripShares");
const mine = (uid) => db.collection("optimizer").doc(uid);

const sha = (s) => crypto.createHash("sha1").update(s).digest("hex");
const lower = (e) => String(e || "").trim().toLowerCase();
const isEmail = (e) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

function requireUser(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  const email = lower(request.auth.token.email);
  if (!email) throw new HttpsError("failed-precondition", "Your account has no email address.");
  return { uid: request.auth.uid, email };
}

async function nameOf(uid, fallback) {
  const d = uid ? (await people.doc(uid).get()).data() : null;
  return (d && d.name) || fallback;
}

async function personByEmail(email) {
  const snap = await people.where("email", "==", lower(email)).limit(1).get();
  return snap.empty ? null : { uid: snap.docs[0].id, ...snap.docs[0].data() };
}

/** The organizer's time zone (from a device of theirs), for wording times in emails. */
async function timeZoneOf(uid) {
  const devices = await db.collection("axisCalendar").doc(uid).collection("devices").limit(5).get();
  for (const d of devices.docs) if (d.data().timeZone) return d.data().timeZone;
  return "America/Chicago";
}

function whenText(ev, tz) {
  if (!ev) return "";
  const start = new Date(ev.start);
  try {
    if (ev.allDay) return start.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: "UTC" });
    return start.toLocaleString("en-US", {
      weekday: "long", month: "long", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: tz, timeZoneName: "short",
    });
  } catch (_) {
    return start.toUTCString();
  }
}

const escape = (s) => String(s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

/** The invitation email for someone not on Optimizer yet. */
function inviteEmail({ fromName, what, when, link }) {
  return `<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#111">
  <p style="font-size:18px;margin:0 0 6px"><b>${escape(fromName)}</b> invited you to</p>
  <p style="font-size:24px;font-weight:800;margin:0 0 6px">${escape(what)}</p>
  ${when ? `<p style="color:#555;margin:0 0 20px">${escape(when)}</p>` : '<div style="height:14px"></div>'}
  <a href="${link}" style="display:inline-block;background:#111;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:700">See the invitation</a>
  <p style="color:#666;font-size:13px;margin:22px 0 0">${escape(fromName)} uses Optimizer for their calendar. The button opens Optimizer, where you can make a free account to answer, with this email address or your Google account. Replying to this email reaches ${escape(fromName)}.</p>
</div>`;
}

const linkFor = (token) => `${SITE}/?invite=${token}`;

// ---------------------------------------------------------------- the copies

/** Rewrites everyone's copy of an event's guest list and invitations. */
async function refreshEvent(eventId) {
  const ev = (await eventsCol.doc(eventId).get()).data();
  if (!ev) return;
  const list = (await invites.where("eventId", "==", eventId).get()).docs;
  const guests = await Promise.all(list.map(async (d) => {
    const i = d.data();
    return { email: i.to, name: await nameOf(i.toUid, ""), status: i.status, inviteId: d.id };
  }));
  guests.sort((a, b) => a.email.localeCompare(b.email));
  const batch = db.batch();
  batch.set(mine(ev.owner).collection("sentEvents").doc(eventId), {
    eventKey: ev.eventKey,
    title: ev.event.title,
    guestsCanSeeList: ev.guestsCanSeeList,
    guests,
    updatedAt: FieldValue.serverTimestamp(),
  });
  const organizer = { email: ev.ownerEmail, name: ev.ownerName, status: "organizer" };
  for (const d of list) {
    const i = d.data();
    if (!i.toUid) continue;
    batch.set(mine(i.toUid).collection("invites").doc(d.id), {
      kind: "event",
      status: i.status,
      fromName: ev.ownerName,
      fromEmail: ev.ownerEmail,
      eventId,
      event: ev.event,
      guests: ev.guestsCanSeeList ? [organizer, ...guests.map(({ email, name, status }) => ({ email, name, status }))] : null,
      createdAt: i.createdAt,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
}

/** Rewrites everyone's copy of a group: its members, and invitations to it. */
async function refreshGroup(groupId) {
  const g = (await groupsCol.doc(groupId).get()).data();
  if (!g) return;
  const list = (await invites.where("groupId", "==", groupId).get()).docs;
  const members = [
    { email: g.ownerEmail, name: g.ownerName, status: "owner" },
    ...(await Promise.all(list.map(async (d) => {
      const i = d.data();
      return { email: i.to, name: await nameOf(i.toUid, ""), status: i.status };
    }))).sort((a, b) => a.email.localeCompare(b.email)),
  ];
  const copy = (role) => ({
    name: g.name,
    owner: g.owner,
    ownerName: g.ownerName,
    role,
    members,
    updatedAt: FieldValue.serverTimestamp(),
  });
  const batch = db.batch();
  batch.set(mine(g.owner).collection("groups").doc(groupId), copy("owner"));
  for (const d of list) {
    const i = d.data();
    if (!i.toUid) continue;
    if (i.status === "accepted") batch.set(mine(i.toUid).collection("groups").doc(groupId), copy("member"));
    else batch.delete(mine(i.toUid).collection("groups").doc(groupId));
    batch.set(mine(i.toUid).collection("invites").doc(d.id), {
      kind: "group",
      status: i.status,
      fromName: g.ownerName,
      fromEmail: g.ownerEmail,
      groupId,
      group: { name: g.name, members: members.length },
      createdAt: i.createdAt,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
}

/** Rewrites everyone's copy of a shared trip, each with only what they may see. */
async function refreshTrip(shareId) {
  const share = (await sharesCol.doc(shareId).get()).data();
  if (!share) return;
  const trip = (await mine(share.owner).collection("trips").doc(share.tripId).get()).data();
  const list = (await invites.where("tripShareId", "==", shareId).get()).docs;
  // The trip's gone: so is everyone's copy, and the sharing.
  if (!trip) {
    for (const d of list) await dropInvite(d);
    await mine(share.owner).collection("tripPeople").doc(share.tripId).delete();
    await sharesCol.doc(shareId).delete();
    return;
  }
  const entries = await Promise.all(list.map(async (d) => {
    const i = d.data();
    return { uid: i.toUid, email: i.to, name: await nameOf(i.toUid, ""), role: ROLES.includes(i.role) ? i.role : "viewer" };
  }));
  entries.sort((a, b) => a.email.localeCompare(b.email));
  const people = entries.map(({ email, name, role }) => ({ email, name, role }));
  const batch = db.batch();
  batch.set(mine(share.owner).collection("tripPeople").doc(share.tripId), { shareId, people, updatedAt: FieldValue.serverTimestamp() });
  for (const p of entries) {
    if (p.uid) batch.set(mine(p.uid).collection("sharedTrips").doc(shareId), { ...tripCopyFor(trip, p, people, { id: shareId, ...share }), updatedAt: FieldValue.serverTimestamp() });
  }
  await batch.commit();
}

async function dropInvite(doc) {
  const i = doc.data();
  if (i.toUid) {
    await mine(i.toUid).collection("invites").doc(doc.id).delete();
    if (i.groupId) await mine(i.toUid).collection("groups").doc(i.groupId).delete();
    if (i.tripShareId) await mine(i.toUid).collection("sharedTrips").doc(i.tripShareId).delete();
  }
  await doc.ref.delete();
}

/**
 * Invites [emails] to an event or group: Optimizer people get a notification;
 * for anyone not on Optimizer, returns their link (to answer and make an
 * account), for you to send them.
 */
async function invitePeople(me, emails, base, describe) {
  const tz = await timeZoneOf(me.uid);
  const links = [];
  for (const email of emails) {
    const person = await personByEmail(email);
    const token = crypto.randomBytes(18).toString("base64url");
    await invites.add({
      ...base,
      from: me.uid,
      fromName: me.name,
      fromEmail: me.email,
      to: email,
      toUid: person ? person.uid : null,
      status: base.status || "pending",
      token,
      createdAt: Timestamp.now(),
    });
    const { what, when } = describe(tz);
    if (person) {
      await notifyUser(person.uid, () => [{
        title: `${me.name} invited you`,
        body: when ? `${what} · ${when}` : what,
        data: { type: "invite" },
      }]).catch((e) => logger.warn("invite notification failed", { message: e.message }));
    } else {
      links.push({ email, link: linkFor(token) });
    }
  }
  return { links };
}

async function whoAmI(request) {
  const me = requireUser(request);
  me.name = await nameOf(me.uid, request.auth.token.name || me.email.split("@")[0]);
  return me;
}

const cleanEmails = (list, me) => [...new Set((Array.isArray(list) ? list : []).map(lower))]
  .filter((e) => isEmail(e) && e !== me.email)
  .slice(0, 100);

const slow = { timeoutSeconds: 120 };

// ---------------------------------------------------------------- you

/** Puts you on Optimizer's list of people (so others can invite you), and picks up invitations sent to your email. */
exports.registerMe = onCall(async (request) => {
  const me = requireUser(request);
  const name = String((request.data && request.data.name) || request.auth.token.name || me.email.split("@")[0]).trim().slice(0, 80);
  await people.doc(me.uid).set({ email: me.email, name, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  const waiting = await invites.where("to", "==", me.email).where("toUid", "==", null).get();
  for (const d of waiting.docs) {
    await d.ref.update({ toUid: me.uid });
    if (d.data().eventId) await refreshEvent(d.data().eventId);
    if (d.data().groupId) await refreshGroup(d.data().groupId);
    if (d.data().tripShareId) await refreshTrip(d.data().tripShareId);
  }
  return { name };
});

/** Which of [emails] are on Optimizer. */
exports.findPeople = onCall(async (request) => {
  const me = requireUser(request);
  const emails = cleanEmails(request.data && request.data.emails, me).slice(0, 50);
  return {
    people: await Promise.all(emails.map(async (email) => {
      const p = await personByEmail(email);
      return { email, registered: !!p, name: p ? p.name : null };
    })),
  };
});

// ---------------------------------------------------------------- events

/**
 * Sets an event's guest list: invites new guests, drops removed ones, and
 * brings everyone's copy of the event up to date (call it on every save of
 * an event with guests; an empty list cancels every invitation).
 */
exports.setEventGuests = onCall(slow, async (request) => {
  const me = await whoAmI(request);
  const d = request.data || {};
  const eventKey = String(d.eventKey || "");
  const e = d.event || {};
  if (!eventKey || !e.title) throw new HttpsError("invalid-argument", "Which event?");
  const guests = cleanEmails(d.guests, me);
  const eventId = sha(`${me.uid}|${eventKey}`).slice(0, 24);
  const ref = eventsCol.doc(eventId);
  const existing = (await invites.where("eventId", "==", eventId).get()).docs;
  if (!guests.length && !existing.length) return { invited: 0, links: [] };

  const event = {
    title: String(e.title).slice(0, 200),
    start: Number(e.start) || 0,
    end: Number(e.end) || 0,
    allDay: !!e.allDay,
    location: String(e.location || "").slice(0, 300),
    description: String(e.description || "").slice(0, 4000),
  };
  await ref.set({
    owner: me.uid,
    ownerName: me.name,
    ownerEmail: me.email,
    eventKey,
    event,
    guestsCanSeeList: d.guestsCanSeeList !== false,
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  const had = new Set(existing.map((x) => x.data().to));
  for (const x of existing) if (!guests.includes(x.data().to)) await dropInvite(x);
  const added = guests.filter((g) => !had.has(g));
  const result = await invitePeople(me, added, { kind: "event", eventId }, (tz) => ({ what: event.title, when: whenText(event, tz) }));
  if (!guests.length) await ref.delete();
  else await refreshEvent(eventId);
  return { invited: added.length, ...result };
});

/** Accept or decline an invitation to an event or a group. */
exports.respondInvite = onCall(async (request) => {
  const me = requireUser(request);
  const id = String((request.data && request.data.inviteId) || "");
  const accept = !!(request.data && request.data.accept);
  const doc = await invites.doc(id).get();
  if (!doc.exists) throw new HttpsError("not-found", "That invitation is gone. It may have been cancelled.");
  const i = doc.data();
  if (i.toUid !== me.uid && i.to !== me.email) throw new HttpsError("permission-denied", "That invitation isn't yours.");
  await doc.ref.update({ status: accept ? "accepted" : "declined", toUid: me.uid, respondedAt: FieldValue.serverTimestamp() });
  let what = "";
  if (i.eventId) {
    await refreshEvent(i.eventId);
    what = ((await eventsCol.doc(i.eventId).get()).data() || {}).event?.title || "your event";
  }
  if (i.groupId) {
    await refreshGroup(i.groupId);
    what = ((await groupsCol.doc(i.groupId).get()).data() || {}).name || "your group";
  }
  const name = await nameOf(me.uid, me.email);
  await notifyUser(i.from, () => [{
    title: `${name} ${accept ? "accepted" : "declined"}`,
    body: what,
    data: { type: "invite-response" },
  }]).catch(() => {});
  return { status: accept ? "accepted" : "declined" };
});

// ---------------------------------------------------------------- groups

/** Makes a group (no [groupId]) or renames yours. */
exports.saveGroup = onCall(async (request) => {
  const me = await whoAmI(request);
  const name = String((request.data && request.data.name) || "").trim().slice(0, 80);
  if (!name) throw new HttpsError("invalid-argument", "Give the group a name.");
  const id = String((request.data && request.data.groupId) || "");
  const ref = id ? groupsCol.doc(id) : groupsCol.doc();
  if (id) {
    const g = await ref.get();
    if (!g.exists || g.data().owner !== me.uid) throw new HttpsError("permission-denied", "Only the group's owner can rename it.");
    await ref.update({ name });
  } else {
    await ref.set({ owner: me.uid, ownerName: me.name, ownerEmail: me.email, name, createdAt: FieldValue.serverTimestamp() });
  }
  await refreshGroup(ref.id);
  return { groupId: ref.id };
});

exports.inviteToGroup = onCall(slow, async (request) => {
  const me = await whoAmI(request);
  const id = String((request.data && request.data.groupId) || "");
  const g = (await groupsCol.doc(id).get()).data();
  if (!g || g.owner !== me.uid) throw new HttpsError("permission-denied", "Only the group's owner can invite people to it.");
  const already = new Set((await invites.where("groupId", "==", id).get()).docs.map((d) => d.data().to));
  const emails = cleanEmails(request.data.emails, me).filter((e) => !already.has(e));
  const result = await invitePeople(me, emails, { kind: "group", groupId: id }, () => ({ what: `the group “${g.name}”`, when: "" }));
  await refreshGroup(id);
  return { invited: emails.length, ...result };
});

/** The owner removes someone, or you leave. */
exports.removeFromGroup = onCall(async (request) => {
  const me = requireUser(request);
  const id = String((request.data && request.data.groupId) || "");
  const email = lower(request.data && request.data.email) || me.email;
  const g = (await groupsCol.doc(id).get()).data();
  if (!g) throw new HttpsError("not-found", "That group is gone.");
  if (g.owner !== me.uid && email !== me.email) throw new HttpsError("permission-denied", "Only the group's owner can remove people.");
  for (const d of (await invites.where("groupId", "==", id).where("to", "==", email).get()).docs) await dropInvite(d);
  await refreshGroup(id);
  return { removed: email };
});

exports.deleteGroup = onCall(async (request) => {
  const me = requireUser(request);
  const id = String((request.data && request.data.groupId) || "");
  const g = (await groupsCol.doc(id).get()).data();
  if (!g || g.owner !== me.uid) throw new HttpsError("permission-denied", "Only the group's owner can delete it.");
  for (const d of (await invites.where("groupId", "==", id).get()).docs) await dropInvite(d);
  await mine(me.uid).collection("groups").doc(id).delete();
  await groupsCol.doc(id).delete();
  return { deleted: true };
});

// ---------------------------------------------------------------- shared trips

const shareIdFor = (uid, tripId) => sha(`trip|${uid}|${tripId}`).slice(0, 24);
const cleanTripId = (v) => {
  const id = String(v || "");
  if (!/^[\w-]{1,200}$/.test(id)) throw new HttpsError("invalid-argument", "Which trip?");
  return id;
};

/**
 * Sets who your trip is shared with: [{ email, role }], role 'editor' or
 * 'viewer'. They see it straight away; anyone not on Optimizer yet gets a link
 * for you to send them. An empty list stops sharing it.
 */
exports.setTripPeople = onCall(slow, async (request) => {
  const me = await whoAmI(request);
  const d = request.data || {};
  const tripId = cleanTripId(d.tripId);
  const trip = (await mine(me.uid).collection("trips").doc(tripId).get()).data();
  if (!trip) throw new HttpsError("not-found", "That trip isn't saved yet. Try again in a moment.");
  const roles = new Map();
  for (const p of Array.isArray(d.people) ? d.people : []) {
    const email = lower(p && p.email);
    if (isEmail(email) && email !== me.email) roles.set(email, p.role === "editor" ? "editor" : "viewer");
  }
  if (roles.size > 100) throw new HttpsError("invalid-argument", "That's more people than a trip can be shared with.");
  const shareId = shareIdFor(me.uid, tripId);
  const ref = sharesCol.doc(shareId);
  const existing = (await invites.where("tripShareId", "==", shareId).get()).docs;
  if (!roles.size && !existing.length) return { invited: 0, links: [] };
  await ref.set({ owner: me.uid, ownerName: me.name, ownerEmail: me.email, tripId, updatedAt: FieldValue.serverTimestamp() }, { merge: true });

  const had = new Map(existing.map((x) => [x.data().to, x]));
  for (const x of existing) {
    const role = roles.get(x.data().to);
    if (!role) await dropInvite(x);
    else if (role !== x.data().role) await x.ref.update({ role });
  }
  const title = String(trip.title || "a trip").slice(0, 200);
  const added = [...roles.keys()].filter((e) => !had.has(e));
  let links = [];
  for (const email of added) {
    const r = await invitePeople(me, [email], { kind: "trip", tripShareId: shareId, role: roles.get(email), status: "accepted", tripTitle: title }, () => ({ what: `the trip “${title}”`, when: "" }));
    links = links.concat(r.links);
  }
  if (!roles.size) {
    await mine(me.uid).collection("tripPeople").doc(tripId).delete();
    await ref.delete();
  } else {
    await refreshTrip(shareId);
  }
  return { invited: added.length, links };
});

/** Brings everyone's copy up to date after you change your trip. */
exports.syncTripShare = onCall(slow, async (request) => {
  const me = requireUser(request);
  const shareId = shareIdFor(me.uid, cleanTripId(request.data && request.data.tripId));
  const share = (await sharesCol.doc(shareId).get()).data();
  if (share && share.owner === me.uid) await refreshTrip(shareId);
  return { ok: true };
});

/** The trip behind a share, and your place on it. Refuses anyone it isn't shared with. */
async function sharedWithMe(me, shareId) {
  const id = String(shareId || "");
  const share = /^[a-f0-9]{24}$/.test(id) ? (await sharesCol.doc(id).get()).data() : null;
  if (!share) throw new HttpsError("not-found", "That trip isn't shared anymore.");
  const mineInvite = (await invites.where("tripShareId", "==", id).where("to", "==", me.email).limit(1).get()).docs[0];
  if (!mineInvite) throw new HttpsError("permission-denied", "That trip isn't shared with you.");
  const invite = mineInvite.data();
  return { id, share, role: invite.role, invite: mineInvite, tripRef: mine(share.owner).collection("trips").doc(share.tripId) };
}

/** Adds or changes an entry on a trip shared with you, if you can edit it. */
exports.saveSharedItem = onCall(slow, async (request) => {
  const me = requireUser(request);
  const d = request.data || {};
  const s = await sharedWithMe(me, d.shareId);
  await db.runTransaction(async (tx) => {
    const trip = (await tx.get(s.tripRef)).data();
    if (!trip) throw new HttpsError("not-found", "That trip is gone.");
    const items = Array.isArray(trip.items) ? trip.items : [];
    const before = items.find((i) => i.id === String(d.item && d.item.id));
    if (roleOnItem(before, me.email, s.role) !== "editor") throw new HttpsError("permission-denied", "You can only view this.");
    const item = cleanSharedItem(d.item, before, (ms) => Timestamp.fromMillis(ms));
    if (!item) throw new HttpsError("invalid-argument", "That entry doesn't look right.");
    tx.update(s.tripRef, { items: [...items.filter((i) => i.id !== item.id), item] });
  });
  await refreshTrip(s.id);
  return { ok: true };
});

/** Takes an entry off a trip shared with you, if you can edit it. */
exports.deleteSharedItem = onCall(slow, async (request) => {
  const me = requireUser(request);
  const d = request.data || {};
  const s = await sharedWithMe(me, d.shareId);
  await db.runTransaction(async (tx) => {
    const trip = (await tx.get(s.tripRef)).data();
    if (!trip) throw new HttpsError("not-found", "That trip is gone.");
    const items = Array.isArray(trip.items) ? trip.items : [];
    const before = items.find((i) => i.id === String(d.itemId));
    if (!before) return;
    if (roleOnItem(before, me.email, s.role) !== "editor") throw new HttpsError("permission-denied", "You can only view this.");
    tx.update(s.tripRef, { items: items.filter((i) => i !== before) });
  });
  await refreshTrip(s.id);
  return { ok: true };
});

/** Changes the details of a trip shared with you (its name, days, notes and links), if you can edit it. */
exports.updateSharedTrip = onCall(slow, async (request) => {
  const me = requireUser(request);
  const d = request.data || {};
  const s = await sharedWithMe(me, d.shareId);
  if (s.role !== "editor") throw new HttpsError("permission-denied", "You can only view this trip.");
  const fields = cleanTripFields(d.fields);
  if (Object.keys(fields).length) await s.tripRef.update(fields);
  await refreshTrip(s.id);
  return { ok: true };
});

/** Takes you off a trip shared with you. */
exports.leaveSharedTrip = onCall(slow, async (request) => {
  const me = requireUser(request);
  const s = await sharedWithMe(me, request.data && request.data.shareId);
  await dropInvite(s.invite);
  await refreshTrip(s.id);
  return { ok: true };
});

// ---------------------------------------------------------------- from an email link

async function byToken(token) {
  const t = String(token || "");
  if (t.length < 16) return null;
  const snap = await invites.where("token", "==", t).limit(1).get();
  return snap.empty ? null : snap.docs[0];
}

/** What an invitation link is for, before signing in (the sign-up page shows it). */
exports.inviteInfo = onCall(async (request) => {
  const doc = await byToken(request.data && request.data.token);
  if (!doc) throw new HttpsError("not-found", "This invitation link doesn't work anymore. Ask for a new one.");
  const i = doc.data();
  let what = "";
  if (i.eventId) what = ((await eventsCol.doc(i.eventId).get()).data() || {}).event?.title || "";
  if (i.groupId) what = `the group “${((await groupsCol.doc(i.groupId).get()).data() || {}).name || ""}”`;
  if (i.tripShareId) what = `the trip “${i.tripTitle || ""}”`;
  return { email: i.to, fromName: i.fromName, what, kind: i.kind };
});

/** After signing up from an invitation link: the invitation is yours (whatever email you used). */
exports.claimInvite = onCall(async (request) => {
  const me = requireUser(request);
  const doc = await byToken(request.data && request.data.token);
  if (!doc) throw new HttpsError("not-found", "This invitation link doesn't work anymore.");
  await doc.ref.update({ to: me.email, toUid: me.uid });
  const i = doc.data();
  if (i.eventId) await refreshEvent(i.eventId);
  if (i.groupId) await refreshGroup(i.groupId);
  if (i.tripShareId) await refreshTrip(i.tripShareId);
  return { kind: i.kind };
});
