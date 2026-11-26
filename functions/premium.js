// Premium beta: early features for accounts switched on in Axis Optic (see
// console.js). Right now: net worth and the assistant.
//
// The switch is the sign-in claim `optimizerPremiumBeta`. Sign-ins (and so
// their claims) are shared with Asset Track and Axis Journal, which is why
// the claim carries the app's name. optimizer/{uid}.premiumBeta is a copy the
// app watches so it refreshes its sign-in right away; only the claim counts.

const { getAuth } = require("firebase-admin/auth");
const { HttpsError } = require("firebase-functions/v2/https");
const { getFirestore } = require("firebase-admin/firestore");

const CLAIM = "optimizerPremiumBeta";

/** Whether a callable's caller (request.auth) has premium beta. */
function hasPremiumBeta(auth) {
  return !!(auth && auth.token && auth.token[CLAIM] === true);
}

/**
 * For a callable that's premium beta's: throws unless the caller is signed in
 * (unauthenticated) and has the claim (permission-denied). The app hides these
 * features without it; this is what actually keeps them closed.
 */
function requirePremiumBeta(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  if (!hasPremiumBeta(request.auth)) throw new HttpsError("permission-denied", "This is a premium beta feature.");
  return request.auth.uid;
}

/** Whether an Auth user record has premium beta. */
function userHasPremiumBeta(u) {
  return !!(u && u.customClaims && u.customClaims[CLAIM] === true);
}

/** Which of these accounts have premium beta, by their sign-in claim (for the every-minute checks). */
async function premiumUids(uids) {
  const out = new Set();
  for (let i = 0; i < uids.length; i += 100) {
    const { users } = await getAuth().getUsers(uids.slice(i, i + 100).map((uid) => ({ uid })));
    for (const u of users) if (userHasPremiumBeta(u)) out.add(u.uid);
  }
  return out;
}

/** Switches premium beta on or off, keeping the account's other claims. */
async function setPremiumBeta(uid, on) {
  const auth = getAuth();
  const u = await auth.getUser(uid);
  const claims = { ...(u.customClaims || {}) };
  if (on) claims[CLAIM] = true;
  else delete claims[CLAIM];
  await auth.setCustomUserClaims(uid, claims);
  // The copy the app listens to, so it refreshes its sign-in now.
  await getFirestore().collection("optimizer").doc(uid).set({ premiumBeta: on }, { merge: true });
}

module.exports = { CLAIM, hasPremiumBeta, requirePremiumBeta, userHasPremiumBeta, premiumUids, setPremiumBeta };
