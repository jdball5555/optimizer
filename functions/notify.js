// Push notifications to a person's phones and browsers
// (axisCalendar/{uid}/devices, registered by the app).

const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");

/** Sends [build](timeZone) to every device the user has turned notifications on for. */
async function notifyUser(uid, build) {
  const devices = await getFirestore().collection("axisCalendar").doc(uid).collection("devices").get();
  const messaging = getMessaging();
  let sent = 0;
  for (const d of devices.docs) {
    const dev = d.data();
    if (!dev.token) continue;
    for (const m of build(dev.timeZone || "UTC")) {
      const link = typeof dev.origin === "string" && dev.origin.startsWith("https://") ? dev.origin : undefined;
      try {
        await messaging.send({
          token: dev.token,
          notification: { title: m.title, body: m.body },
          data: m.data || {},
          webpush: { notification: { icon: "/icons/Icon-192.png" }, ...(link ? { fcmOptions: { link } } : {}) },
          apns: { payload: { aps: { sound: "default" } } },
          android: { priority: "high" },
        });
        sent++;
      } catch (e) {
        const code = e.errorInfo && e.errorInfo.code;
        if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
          await d.ref.delete();
          break;
        }
        logger.warn("notification failed", { uid, code, message: e.message });
      }
    }
  }
  return sent;
}

module.exports = { notifyUser };
