import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/log_redaction.dart';

void main() {
  test('redacts bearer tokens from error text', () {
    expect(
      redactSecret('request failed with Authorization: Bearer secret-token'),
      'request failed with Authorization: Bearer [redacted]',
    );
  });

  test('redacts each named secret from error text', () {
    expect(
      redactSecret(
        'failed with sk-live-123 after client_secret=second-secret',
        ['sk-live-123', 'second-secret'],
      ),
      'failed with [redacted] after client_secret=[redacted]',
    );
  });

  test('redacts sensitive header values and preserves safe headers', () {
    expect(
      redactHeaders({
        'Authorization': 'Bearer x',
        'X-Api-Key': 'key-value',
        'Cookie': 'session=abc',
        'X-Ok': '1',
      }),
      {
        'Authorization': '[redacted]',
        'X-Api-Key': '[redacted]',
        'Cookie': '[redacted]',
        'X-Ok': '1',
      },
    );
  });

  test('removes URL query strings', () {
    expect(
      redactUrl('https://example.test/path?token=abc&x=1'),
      'https://example.test/path',
    );
  });
}
