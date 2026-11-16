// What each person gets to see of a shared trip. No network here, so it can be
// tested: this is what keeps a hidden entry off someone's device.

const ROLES = ["editor", "viewer", "none"];

/** 'editor', 'viewer' or 'none'. An entry can say otherwise for someone; if not, it's what they have on the trip. */
function roleOnItem(item, email, tripRole) {
  const set = item && item.access && item.access[email];
  return ROLES.includes(set) ? set : tripRole;
}

/** Everyone who can see an entry, and how. */
function peopleOnItem(item, people) {
  return people
    .map((p) => ({ email: p.email, name: p.name || "", role: roleOnItem(item, p.email, p.role) }))
    .filter((p) => p.role !== "none");
}

/**
 * [person]'s own copy of [trip]: the entries they may see and nothing about the
 * ones they may not, not even who's been given or denied what on them.
 * [people] is everyone it's shared with, each { email, name, role }.
 */
function tripCopyFor(trip, person, people, share) {
  const items = [];
  for (const item of trip.items || []) {
    const myRole = roleOnItem(item, person.email, person.role);
    if (myRole === "none") continue;
    const { access: _hidden, ...shown } = item;
    items.push({ ...shown, myRole, canSee: peopleOnItem(item, people) });
  }
  const { items: _all, ...details } = trip;
  return {
    ...details,
    items,
    shareId: share.id,
    ownerName: share.ownerName || "",
    ownerEmail: share.ownerEmail || "",
    myRole: person.role,
    people: people.map((p) => ({ email: p.email, name: p.name || "", role: p.role })),
  };
}

const LIMIT = 200000;

/** An entry from someone else's app, cleaned of what only the owner decides. The rest of [before] (who may see it) stays. */
function cleanSharedItem(raw, before, toTime) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const { access: _a, myRole: _m, canSee: _c, ...item } = raw;
  const start = Number(item.start), end = Number(item.end);
  if (!item.id || !Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (JSON.stringify(item).length > LIMIT) return null;
  return {
    ...item,
    id: String(item.id),
    start: toTime(start),
    end: toTime(end),
    ...(before && before.access ? { access: before.access } : {}),
  };
}

/** The trip's details an editor can change, and nothing else. */
function cleanTripFields(raw) {
  const f = raw && typeof raw === "object" ? raw : {};
  const out = {};
  for (const k of ["title", "destination", "startDay", "endDay", "notes"]) {
    if (typeof f[k] === "string") out[k] = f[k].slice(0, k === "notes" ? 20000 : 300);
  }
  if (out.title !== undefined && !out.title.trim()) delete out.title;
  if (Array.isArray(f.links)) {
    out.links = f.links.slice(0, 200)
      .filter((l) => l && typeof l.url === "string" && /^https?:\/\//i.test(l.url))
      .map((l) => ({ url: l.url.slice(0, 2000), label: String(l.label || "").slice(0, 200) }));
  }
  return out;
}

module.exports = { ROLES, roleOnItem, peopleOnItem, tripCopyFor, cleanSharedItem, cleanTripFields };
