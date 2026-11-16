// Template: copy to firebase-messaging-sw.js (kept out of git) with your
// Firebase web app's config.
// Shows Optimizer's notifications (new Canvas assignments and the like) when
// the site isn't open. The browser runs this in the background on its own.
importScripts('https://www.gstatic.com/firebasejs/11.9.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/11.9.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'YOUR_API_KEY',
  appId: 'YOUR_APP_ID',
  messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
  projectId: 'YOUR_PROJECT_ID',
  authDomain: 'YOUR_AUTH_DOMAIN',
  storageBucket: 'YOUR_STORAGE_BUCKET',
});

// Messages carry a `notification`, which Firebase shows by itself; this just
// has to exist. Clicking one opens the link sent with it.
firebase.messaging();
