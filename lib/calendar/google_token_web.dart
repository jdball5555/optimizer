// Links Google Calendar by sending this tab to Google's sign-in page and back
// (OAuth's redirect flow). This deliberately does NOT go through Firebase
// Auth, so linking extra Google accounts never creates or changes users in
// your Axis Firebase project.
//
// It used to open Google in a pop-up, but Google's consent pages cut the
// pop-up's link back to this page partway through, so the code never arrived
// ("The Google window was closed before finishing" while it was still open).
// A redirect has nothing to lose between windows.
import 'dart:math';

import 'package:web/web.dart' as web;

const _stateKey = 'optimizer.googleConnectState';

/// Where Google sends you back to. It has to be listed exactly under
/// "Authorized redirect URIs" on the OAuth client in Google Cloud Console.
String get googleRedirectUri => '${web.window.location.origin}/';

/// What Google sent this page back with, read once at startup (before
/// anything changes the address).
({String? code, String? error})? _returned = _readReturn();

({String? code, String? error})? _readReturn() {
  final q = Uri.base.queryParameters;
  if (!q.containsKey('code') && !q.containsKey('error')) return null;
  final String? expected;
  try {
    expected = web.window.sessionStorage.getItem(_stateKey);
    web.window.sessionStorage.removeItem(_stateKey);
  } catch (_) {
    return null;
  }
  // Not one Optimizer started (or a stale one): leave it alone.
  if (expected == null || q['state'] != expected) return null;

  // Take it out of the address so a reload doesn't use it twice.
  const google = {'code', 'state', 'scope', 'error', 'authuser', 'prompt', 'hd', 'iss'};
  final rest = Uri(queryParameters: {
    for (final e in q.entries)
      if (!google.contains(e.key)) e.key: e.value,
  }).query;
  final loc = web.window.location;
  web.window.history.replaceState(null, '', '${loc.pathname}${rest.isEmpty ? '' : '?$rest'}${loc.hash}');

  return (code: q['code'], error: q['error']);
}

/// Reads the address now, so it's taken before the app starts routing.
void captureGoogleReturn() => _returned;

/// The code Google came back with, once. Null if this page load isn't a
/// return from Google. Throws if Google said no.
String? takeGoogleCode() {
  final r = _returned;
  _returned = null;
  if (r == null) return null;
  if (r.code != null) return r.code;
  throw Exception(r.error == 'access_denied'
      ? 'Calendar access wasn’t allowed. Try again and tick “See, edit, share and delete all your calendars”.'
      : 'Google sign-in failed: ${r.error}');
}

/// Sends this tab to Google to allow calendar access. It comes back to
/// Optimizer, where [takeGoogleCode] picks up the result.
Future<void> startGoogleConnect({
  required String clientId,
  required String scope,
  String? hint,
}) async {
  if (clientId.startsWith('PASTE_')) {
    throw Exception('Set AppConfig.googleWebClientId in lib/config.dart first.');
  }
  final rnd = Random.secure();
  final state = List.generate(24, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  try {
    web.window.sessionStorage.setItem(_stateKey, state);
  } catch (_) {
    throw Exception('This browser won’t let Optimizer remember the sign-in while you’re at Google (private window?). Try a normal window.');
  }
  final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': clientId,
    'redirect_uri': googleRedirectUri,
    'response_type': 'code',
    'scope': scope,
    'state': state,
    // A lasting sign-in, so the server can keep syncing; asking each time
    // makes sure Google hands one over.
    'access_type': 'offline',
    'prompt': hint == null ? 'select_account consent' : 'consent',
    'include_granted_scopes': 'true',
    if (hint != null) 'login_hint': hint,
  });
  web.window.location.assign(url.toString());
}
