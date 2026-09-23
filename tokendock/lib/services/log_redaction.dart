final _sensitiveHeader = RegExp(
  r'key|token|secret|auth|credential|cookie',
  caseSensitive: false,
);

String redactSecret(String input, [List<String> secrets = const []]) {
  var redacted = input;
  for (final secret in secrets) {
    if (secret.isNotEmpty) {
      redacted = redacted.replaceAll(secret, '[redacted]');
    }
  }
  return redacted.replaceAllMapped(
    RegExp(r'''(Bearer\s+)[^\s"',}]+''', caseSensitive: false),
    (match) => '${match.group(1)}[redacted]',
  );
}

Map<String, String> redactHeaders(Map<String, String> headers) {
  return headers.map(
    (name, value) => MapEntry(
      name,
      _sensitiveHeader.hasMatch(name) ? '[redacted]' : value,
    ),
  );
}

String redactUrl(String url) {
  final queryStart = url.indexOf('?');
  return queryStart == -1 ? url : url.substring(0, queryStart);
}
