// Picks the web implementation (Google Identity Services) when compiled for
// the browser, and a stub elsewhere.
export 'google_token_stub.dart' if (dart.library.js_interop) 'google_token_web.dart';
