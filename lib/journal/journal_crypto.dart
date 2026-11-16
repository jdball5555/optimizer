import 'package:encrypt/encrypt.dart' as encrypt;

import 'journal_key.dart';

/// Same scheme as Axis Journal's EncryptionService, so entries stay readable
/// in both apps: AES-256 with a random IV, stored as `iv:ciphertext`.
/// The key lives in journal_key.dart, which is kept out of git
/// (journal_key.example.dart shows its shape).
class JournalCrypto {
  static final _encrypter = encrypt.Encrypter(encrypt.AES(encrypt.Key.fromUtf8(journalKey)));

  static String encryptText(String plain) {
    if (plain.isEmpty) return '';
    final iv = encrypt.IV.fromSecureRandom(16);
    return '${iv.base64}:${_encrypter.encrypt(plain, iv: iv).base64}';
  }

  // Decrypting is slow-ish and the whole journal is re-read on every change,
  // so each distinct ciphertext is decrypted once.
  static final _plain = <String, String>{};

  /// Returns [text] unchanged if it isn't something Axis Journal encrypted.
  static String decryptText(String text) {
    if (text.isEmpty) return '';
    return _plain[text] ??= _decrypt(text);
  }

  static String _decrypt(String text) {
    try {
      final parts = text.split(':');
      if (parts.length == 2) return _encrypter.decrypt64(parts[1], iv: encrypt.IV.fromBase64(parts[0]));
      // Axis Journal's legacy entries used an all-zero IV.
      return _encrypter.decrypt64(text, iv: encrypt.IV.fromLength(16));
    } catch (_) {
      return text;
    }
  }
}
