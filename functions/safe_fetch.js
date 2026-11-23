// Fetching a link someone gave us (a Canvas calendar feed) without letting it
// reach anything that isn't on the public internet: the server's own metadata
// service, Google's internal network, or a private address behind a redirect.
//
// Every hop is checked before it's fetched: https only, no internal host
// names, and every address the host resolves to must be public. Redirects are
// followed by hand (at most 5) so each one gets the same check.

const dns = require("dns");
const net = require("net");

const MAX_REDIRECTS = 5;

/** Host names that are internal by name, whatever they resolve to. */
function isBlockedHostName(host) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  return !h || h === "localhost" || h.endsWith(".localhost") || h.endsWith(".internal") || h.endsWith(".local");
}

function v4Parts(ip) {
  const p = ip.split(".").map(Number);
  return p.length === 4 && p.every((n) => Number.isInteger(n) && n >= 0 && n <= 255) ? p : null;
}

/** An IPv4 address that isn't public: private, loopback, link-local (the metadata server), CGNAT, unspecified, multicast or reserved. */
function isBlockedV4(ip) {
  const p = v4Parts(ip);
  if (!p) return true;
  const [a, b] = p;
  return a === 0 || // unspecified, "this network"
    a === 10 || // private
    a === 127 || // loopback
    (a === 100 && b >= 64 && b <= 127) || // CGNAT 100.64.0.0/10
    (a === 169 && b === 254) || // link-local, including 169.254.169.254 (metadata)
    (a === 172 && b >= 16 && b <= 31) || // private
    (a === 192 && b === 168) || // private
    (a === 192 && b === 0 && p[2] === 0) || // IETF protocol assignments
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    a >= 224; // multicast, reserved, broadcast
}

/** The 8 groups of an IPv6 address, as numbers (with an embedded IPv4 tail expanded), or null. */
function v6Groups(ip) {
  let s = ip.toLowerCase().split("%")[0];
  const tail = s.match(/(\d+\.\d+\.\d+\.\d+)$/);
  if (tail) {
    const p = v4Parts(tail[1]);
    if (!p) return null;
    s = s.slice(0, -tail[1].length) + ((p[0] << 8) | p[1]).toString(16) + ":" + ((p[2] << 8) | p[3]).toString(16);
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = halves.length === 2 ? 8 - head.length - rest.length : 0;
  const all = [...head, ...Array(Math.max(fill, 0)).fill("0"), ...rest];
  if (all.length !== 8) return null;
  const nums = all.map((g) => parseInt(g, 16));
  return nums.every((n) => Number.isInteger(n) && n >= 0 && n <= 0xffff) ? nums : null;
}

/** An IPv6 address that isn't public: unspecified, loopback, unique local, link-local, multicast, or an IPv4 one that isn't. */
function isBlockedV6(ip) {
  const g = v6Groups(ip);
  if (!g) return true;
  if (g.every((n) => n === 0)) return true; // ::
  if (g.slice(0, 7).every((n) => n === 0) && g[7] === 1) return true; // ::1
  if ((g[0] & 0xfe00) === 0xfc00) return true; // fc00::/7 unique local
  if ((g[0] & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((g[0] & 0xff00) === 0xff00) return true; // multicast
  const v4 = (hi, lo) => `${hi >> 8}.${hi & 0xff}.${lo >> 8}.${lo & 0xff}`;
  // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d) and NAT64 (64:ff9b::a.b.c.d): judge the IPv4 inside.
  if (g.slice(0, 5).every((n) => n === 0) && (g[5] === 0xffff || g[5] === 0)) return isBlockedV4(v4(g[6], g[7]));
  if (g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((n) => n === 0)) return isBlockedV4(v4(g[6], g[7]));
  return false;
}

/** Whether an IP address (v4 or v6) is anywhere but the public internet. */
function isBlockedAddress(ip) {
  const kind = net.isIP(String(ip || ""));
  if (kind === 4) return isBlockedV4(ip);
  if (kind === 6) return isBlockedV6(ip);
  return true;
}

/** Throws unless [url] is https to a public host (by name and by every address it resolves to). */
async function checkPublicUrl(url, lookup = dns.promises.lookup) {
  let u;
  try {
    u = new URL(url);
  } catch (_) {
    throw new Error("That isn't a link.");
  }
  if (u.protocol !== "https:") throw new Error("Only https links can be read.");
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (isBlockedHostName(host)) throw new Error("That link points somewhere private.");
  let addresses;
  if (net.isIP(host)) {
    addresses = [{ address: host }];
  } else {
    try {
      addresses = await lookup(host, { all: true });
    } catch (_) {
      throw new Error(`Couldn't find ${host}.`);
    }
  }
  if (!addresses.length || addresses.some((a) => isBlockedAddress(a.address))) {
    throw new Error("That link points somewhere private.");
  }
  return u;
}

/**
 * fetch(), for a link from someone else: each hop (the link and up to 5
 * redirects) is checked with [checkPublicUrl] before it's requested.
 */
async function fetchPublic(url, init = {}, { lookup, fetchImpl = fetch } = {}) {
  let next = url;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const u = await checkPublicUrl(next, lookup);
    const res = await fetchImpl(u.toString(), { ...init, redirect: "manual" });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      next = new URL(res.headers.get("location"), u).toString();
      continue;
    }
    return res;
  }
  throw new Error("Too many redirects.");
}

module.exports = { MAX_REDIRECTS, isBlockedHostName, isBlockedAddress, checkPublicUrl, fetchPublic };
