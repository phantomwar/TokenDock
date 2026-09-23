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

  test('redacts overlapping secrets without leaking their suffix', () {
    expect(
      redactSecret('failed with secret-value', ['secret', 'secret-value']),
      'failed with [redacted]',
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

  test('preserves URL fragments while removing preceding query strings', () {
    expect(
      redactUrl('https://example.test/path?token=abc#usage'),
      'https://example.test/path#usage',
    );
    expect(
      redactUrl('https://example.test/path#usage?literal=true'),
      'https://example.test/path#usage?literal=true',
    );
  });

  test('redacts named credential fields in JSON and case variants', () {
    const input = '{"access_token":"a","refreshToken":"r","client_secret":"s",'
        '"id_token":"i","Authorization":"Bearer h","cookie":"c","api_key":"k"}';

    final redacted = redactSecret(input);

    for (final value in ['"a"', '"r"', '"s"', '"i"', 'Bearer h', '"c"', '"k"']) {
      expect(redacted, isNot(contains(value)));
    }
    expect(redacted, contains('access_token'));
    expect(redacted, contains('refreshToken'));
  });

  test('redacts named query-like credential fields without removing URL rules', () {
    final redacted = redactSecret(
      'client-secret=credential ACCESS_TOKEN=value apiKey: value',
    );
    expect(redacted, isNot(contains('credential')));
    expect(redacted, isNot(contains('value')));
    expect(
      redactUrl('https://example.test/callback?state=abc#done'),
      'https://example.test/callback#done',
    );
  });

  test('redacts credential-named JSON fields by substring', () {
    const input = '{"token":"token-value","credential":"credential-value",'
        '"oauth":"oauth-value","private_key":"private-value"}';

    final redacted = redactSecret(input);

    for (final value in [
      'token-value',
      'credential-value',
      'oauth-value',
      'private-value',
    ]) {
      expect(redacted, isNot(contains(value)));
    }
    expect(redacted, contains('token'));
    expect(redacted, contains('credential'));
  });
}
