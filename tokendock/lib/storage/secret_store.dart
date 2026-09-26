import 'dart:math';
import 'dart:typed_data';

/// Interface for storing, retrieving, and deleting sensitive credentials.
abstract interface class SecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Substrings that mark a field name as carrying credential material.
///
/// Canonical definition shared by log redaction ([`redactSecret`]) and the
/// SQLite `provider_data` sanitiser, so the last line of defence against
/// writing a token into the database cannot drift from the redaction rules.
///
/// [redactSecret]: ../services/log_redaction.dart
const List<String> sensitiveKeyMarkers = <String>[
  'key',
  'token',
  'secret',
  'auth',
  'credential',
  'cookie',
];

final RegExp _sensitiveKeyPattern = RegExp(
  sensitiveKeyMarkers.join('|'),
  caseSensitive: false,
);

/// Whether [name] identifies a field that must never be persisted in the
/// clear, whether it is a JSON object key, a header name, or a query
/// parameter.
bool isSensitiveKeyName(String name) => _sensitiveKeyPattern.hasMatch(name);

/// Generates a standard RFC 4122 compliant UUIDv4 string using 16 [Random.secure] bytes.
///
/// Format: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where y is 8, 9, a, or b.
String generateSecretRef() {
  final random = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = random.nextInt(256);
  }

  // Set version to 4 (0100 in high nibble of byte 6)
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  // Set variant to RFC 4122 (10xx in high bits of byte 8)
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      buffer.write('-');
    }
    buffer.write(hex(bytes[i]));
  }
  return buffer.toString();
}

/// Masks an API key or secret safely.
///
/// Returns prefix (e.g. `sk-` or leading characters) plus `...` plus the final
/// 4 characters (e.g. `sk-...1234`). For short strings (<= 8 chars), returns `****`.
/// Never returns the full secret.
String maskSecret(String value) {
  if (value.length <= 8) {
    return '****';
  }
  final prefix = value.substring(0, 3);
  final suffix = value.substring(value.length - 4);
  return '$prefix...$suffix';
}
