import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Bumped after your name changes (making an account, or Settings), so the
/// app picks up the new name: Firebase's sign-in stream doesn't say when a
/// name changes, and the account it handed over still has the old one.
final profileChanged = ValueNotifier(0);

/// Sets your name and tells the app (see [profileChanged]).
Future<void> saveDisplayName(User user, String name) async {
  await user.updateDisplayName(name.trim());
  await user.reload();
  profileChanged.value++;
}
