String get googleRedirectUri => '';

void captureGoogleReturn() {}

String? takeGoogleCode() => null;

Future<void> startGoogleConnect({
  required String clientId,
  required String scope,
  String? hint,
}) async {
  throw UnsupportedError('Linking Google Calendar is only available in the web version for now.');
}
