// Optimizer's own email (invitations to people not on Optimizer yet), sent
// through Resend from an address on axisoptic.com, with replies going to the
// person who sent the invitation.
//
// Not used yet (for now people not on Optimizer get a link you send them).
// To turn on: verify axisoptic.com in Resend (its DNS records go in
// Cloudflare), `firebase functions:secrets:set RESEND_API_KEY`, and have
// people.js send inviteEmail() through sendEmail() for them.

const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

const RESEND_API_KEY = defineSecret("RESEND_API_KEY");
const EMAIL_FROM = defineString("EMAIL_FROM", { default: "Optimizer <invites@axisoptic.com>" });

/** Sends one email; false if it couldn't (the app then offers the link to share). */
async function sendEmail({ to, subject, html, replyTo }) {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY.value()}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: EMAIL_FROM.value(), to: [to], subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) {
      logger.warn("email failed", { status: res.status, body: (await res.text()).slice(0, 300) });
      return false;
    }
    return true;
  } catch (e) {
    logger.warn("email failed", { message: e.message });
    return false;
  }
}

module.exports = { sendEmail, RESEND_API_KEY };
