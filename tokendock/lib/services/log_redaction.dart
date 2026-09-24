import 'dart:convert';

final _sensitiveHeader = RegExp(
  r'key|token|secret|auth|credential|cookie',
  caseSensitive: false,
);

String redactSecret(String input, [List<String> secrets = const []]) {
  var redacted = input;
  final orderedSecrets = secrets.where((secret) => secret.isNotEmpty).toList()
    ..sort((left, right) => right.length.compareTo(left.length));
  for (final secret in orderedSecrets) {
    redacted = redacted.replaceAll(secret, '[redacted]');
  }
  final jsonRedacted = _tryRedactJson(redacted);
  if (jsonRedacted != null) return jsonRedacted;
  redacted = redacted.replaceAllMapped(
    RegExp(r'''(Bearer\s+)[^\s"',}]+''', caseSensitive: false),
    (match) => '${match.group(1)}[redacted]',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(
      r'''(["']?[^:=\s"',{}]*(?:key|token|secret|auth|credential|cookie)[^:=\s"',{}]*["']?\s*[:=]\s*)(?!(?:Bearer\s+)?\[redacted\])("[^"]*"|'[^']*'|[^\s,;}\]]+)''',
      caseSensitive: false,
    ),
    (match) {
      final prefix = match.group(1)!;
      final value = match.group(2)!;
      if (prefix.toLowerCase().contains('authorization') &&
          value.trimLeft().toLowerCase().startsWith('bearer ')) {
        return '$prefix' 'Bearer [redacted]';
      }
      return '$prefix[redacted]';
    },
  );
  return redacted;
}

String? _tryRedactJson(String input) {
  try {
    final decoded = jsonDecode(input);
    if (decoded is! Map && decoded is! List) return null;
    return jsonEncode(_redactJsonValue(decoded));
  } catch (_) {
    return null;
  }
}

dynamic _redactJsonValue(dynamic value, {String? fieldName}) {
  if (fieldName != null && _sensitiveHeader.hasMatch(fieldName)) {
    if (fieldName.toLowerCase().contains('authorization') &&
        value is String &&
        value.toLowerCase().startsWith('bearer ')) {
      return 'Bearer [redacted]';
    }
    return '[redacted]';
  }
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(
        key.toString(),
        _redactJsonValue(child, fieldName: key.toString()),
      ),
    );
  }
  if (value is List) {
    return value.map((child) => _redactJsonValue(child)).toList();
  }
  return value;
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
  final fragmentStart = url.indexOf('#');
  if (queryStart == -1 ||
      (fragmentStart != -1 && queryStart > fragmentStart)) {
    return url;
  }
  final queryEnd = fragmentStart == -1 ? url.length : fragmentStart;
  return url.replaceRange(queryStart, queryEnd, '');
}
