// Premium beta: early features for accounts switched on in Axis Optic (see
// optic.js). Right now: net worth and the assistant.
//
// The switch is the sign-in claim `optimizerPremiumBeta`. Sign-ins (and so
// their claims) are shared with Asset Track and Axis Journal, which is why
// the claim carries the app's name. optimizer/{uid}.premiumBeta is a copy the
// app watches so it refreshes its sign-in right away; only the claim counts.

const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");

const CLAIM = "optimizerPremiumBeta";

/** Whether a callable's caller (request.auth) has premium beta. */
function hasPremiumBeta(auth) {
  return !!(auth && auth.token && auth.token[CLAIM] === true);
}

/** Whether an Auth user record has premium beta. */
function userHasPremiumBeta(u) {
  return !!(u && u.customClaims && u.customClaims[CLAIM] === true);
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

module.exports = { CLAIM, hasPremiumBeta, userHasPremiumBeta, setPremiumBeta };
