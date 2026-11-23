// node test_safe_fetch.js — links from users can't reach anything private.
const assert = require("assert");
const { isBlockedHostName, isBlockedAddress, checkPublicUrl, fetchPublic } = require("./safe_fetch");

// Addresses.
for (const ip of [
  "0.0.0.0", "10.1.2.3", "127.0.0.1", "100.64.0.1", "100.127.255.255", "169.254.169.254", "172.16.0.1", "172.31.255.255",
  "192.168.1.1", "192.0.0.8", "198.18.0.1", "224.0.0.1", "255.255.255.255",
  "::", "::1", "fc00::1", "fd12:3456::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:a9fe:a9fe",
  "64:ff9b::10.0.0.1", "not an ip", "",
]) {
  assert.strictEqual(isBlockedAddress(ip), true, ip);
}
for (const ip of ["8.8.8.8", "151.101.1.1", "100.128.0.1", "172.32.0.1", "2607:f8b0:4004::200e", "::ffff:8.8.8.8", "64:ff9b::8.8.8.8"]) {
  assert.strictEqual(isBlockedAddress(ip), false, ip);
}

// Names.
for (const h of ["localhost", "LOCALHOST.", "x.localhost", "metadata.google.internal", "printer.local", ""]) {
  assert.strictEqual(isBlockedHostName(h), true, h);
}
assert.strictEqual(isBlockedHostName("school.instructure.com"), false);

(async () => {
  const fakeDns = (table) => async (host) => {
    if (!(host in table)) throw new Error("ENOTFOUND");
    return table[host].map((address) => ({ address }));
  };
  const dns = fakeDns({
    "school.instructure.com": ["151.101.1.1"],
    "sneaky.example.com": ["151.101.1.1", "10.0.0.5"], // one private address is enough to refuse
    "meta.example.com": ["169.254.169.254"],
    "v6.example.com": ["fd00::1"],
  });
  const refused = async (url) => assert.rejects(checkPublicUrl(url, dns), /private|https|find|isn't a link/, url);

  await checkPublicUrl("https://school.instructure.com/feeds/calendars/user_x.ics", dns);
  await refused("http://school.instructure.com/feeds/calendars/user_x.ics");
  await refused("https://sneaky.example.com/x.ics");
  await refused("https://meta.example.com/x.ics");
  await refused("https://v6.example.com/x.ics");
  await refused("https://169.254.169.254/computeMetadata/v1/");
  await refused("https://[::1]/x.ics");
  await refused("https://localhost/x.ics");
  await refused("https://nowhere.example.com/x.ics");
  await refused("not a link");

  // Redirects: followed by hand, each hop checked; too many is refused.
  const responses = (map) => async (url, init) => {
    assert.strictEqual(init.redirect, "manual");
    const to = map[url];
    return to
      ? { status: 302, headers: { get: (k) => (k === "location" ? to : null) } }
      : { status: 200, headers: { get: () => null }, url };
  };
  const start = "https://school.instructure.com/feeds/calendars/user_x.ics";
  const ok = await fetchPublic(start, {}, { lookup: dns, fetchImpl: responses({ [start]: "/feeds/calendars/user_y.ics" }) });
  assert.strictEqual(ok.url, "https://school.instructure.com/feeds/calendars/user_y.ics");
  await assert.rejects(
    fetchPublic(start, {}, { lookup: dns, fetchImpl: responses({ [start]: "https://meta.example.com/latest" }) }), /private/);
  await assert.rejects(
    fetchPublic(start, {}, { lookup: dns, fetchImpl: responses({ [start]: "http://school.instructure.com/x" }) }), /https/);
  const loop = {};
  for (let i = 0; i < 7; i++) loop[`https://school.instructure.com/${i}`] = `https://school.instructure.com/${i + 1}`;
  await assert.rejects(fetchPublic("https://school.instructure.com/0", {}, { lookup: dns, fetchImpl: responses(loop) }), /Too many redirects/);

  console.log("safe fetch ok");
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
