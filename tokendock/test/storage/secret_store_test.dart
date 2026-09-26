import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/storage/secret_store.dart';
import 'package:tokendock/storage/secure_secret_store.dart';

import '../support/memory_secret_store.dart';

class _FakeFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _data[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }
}

void main() {
  group('MemorySecretStore', () {
    late MemorySecretStore store;

    setUp(() {
      store = MemorySecretStore();
    });

    test('writes and reads a secret value', () async {
      await store.write('api_key_ref_1', 'val_1');
      final result = await store.read('api_key_ref_1');
      expect(result, equals('val_1'));
    });

    test('returns null when reading non-existent key', () async {
      final result = await store.read('non_existent');
      expect(result, isNull);
    });

    test('overwrites an existing secret', () async {
      await store.write('ref_1', 'old_val');
      await store.write('ref_1', 'new_val');
      final result = await store.read('ref_1');
      expect(result, equals('new_val'));
    });

    test('deletes a secret', () async {
      await store.write('ref_1', 'val_1');
      await store.delete('ref_1');
      final result = await store.read('ref_1');
      expect(result, isNull);
    });

    test('deleting one key leaves others intact (isolation)', () async {
      await store.write('key_a', 'val_a');
      await store.write('key_b', 'val_b');
      await store.write('key_c', 'val_c');

      await store.delete('key_b');

      expect(await store.read('key_a'), equals('val_a'));
      expect(await store.read('key_b'), isNull);
      expect(await store.read('key_c'), equals('val_c'));
    });

    test('supports initial data and clear', () async {
      final preloaded = MemorySecretStore({'k1': 'v1', 'k2': 'v2'});
      expect(await preloaded.read('k1'), equals('v1'));
      expect(await preloaded.read('k2'), equals('v2'));

      preloaded.clear();
      expect(await preloaded.read('k1'), isNull);
      expect(preloaded.entries, isEmpty);
    });
  });

  group('generateSecretRef', () {
    final uuidV4Regex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    test('generates valid RFC 4122 UUIDv4 formatted string', () {
      final ref = generateSecretRef();
      expect(ref, matches(uuidV4Regex));
      expect(ref.length, equals(36));
      expect(ref[14], equals('4'));
      expect(['8', '9', 'a', 'b'], contains(ref[19]));
    });

    test('successive calls generate distinct references', () {
      const count = 100;
      final refs = <String>{};
      for (var i = 0; i < count; i++) {
        final ref = generateSecretRef();
        expect(ref, matches(uuidV4Regex));
        refs.add(ref);
      }
      expect(refs.length, equals(count));
    });
  });

  group('maskSecret', () {
    // U+2022, written as an escape so the expectation cannot be corrupted by a
    // tool that guesses the file's encoding. Not `const`: `String * int` is
    // not a constant expression.
    final bullets = secretMaskGlyph * secretMaskLength;

    test('masks standard keys ending with last 4 characters and redacted middle', () {
      const secret = 'sk-or-v1-abcdef0123456789';
      final masked = maskSecret(secret);

      // The spec's masked form is `sk-` + ten bullets + the last four. A fixed
      // bullet run, not an ellipsis: an ellipsis reads as a truncated value
      // (audit C-34).
      expect(masked, equals('sk-${bullets}6789'));
      expect(masked.endsWith('6789'), isTrue);
      expect(masked.startsWith('sk-'), isTrue);
      expect(masked, isNot(contains('...')));
      expect(masked, isNot(equals(secret)));
      expect(secret.contains(masked), isFalse);
    });

    test('the masked form is the same length for every long credential', () {
      // A variable-width mask would reflow the field between connections.
      expect(
        maskSecret('sk-or-v1-abcdef0123456789').length,
        maskSecret('123456789').length,
      );
    });

    test('masks arbitrary keys with leading characters prefix', () {
      const key = 'abcdefghijklmnop';
      final masked = maskSecret(key);
      expect(masked, equals('abc${bullets}mnop'));
      expect(masked.endsWith('mnop'), isTrue);
      expect(masked.startsWith('abc'), isTrue);
    });

    test('masks keys of length 9 correctly', () {
      const key = '123456789';
      final masked = maskSecret(key);
      expect(masked, equals('123${bullets}6789'));
    });

    test('masks short strings (<= 8 characters) with **** safely', () {
      expect(maskSecret(''), equals('****'));
      expect(maskSecret('a'), equals('****'));
      expect(maskSecret('1234'), equals('****'));
      expect(maskSecret('sk-1234'), equals('****'));
      expect(maskSecret('12345678'), equals('****'));
    });
  });

  group('SecureSecretStore', () {
    late _FakeFlutterSecureStorage fakeStorage;
    late SecureSecretStore store;

    setUp(() {
      fakeStorage = _FakeFlutterSecureStorage();
      store = SecureSecretStore(storage: fakeStorage);
    });

    test('instantiates with default constructor without error', () {
      final defaultStore = SecureSecretStore();
      expect(defaultStore, isNotNull);
      expect(defaultStore, isA<SecretStore>());
    });

    test('writes and reads secret via injected storage', () async {
      await store.write('secret_ref_1', 'top_secret_val');
      final result = await store.read('secret_ref_1');
      expect(result, equals('top_secret_val'));
    });

    test(
      'returns null when reading non-existent key via injected storage',
      () async {
        final result = await store.read('missing_key');
        expect(result, isNull);
      },
    );

    test('overwrites an existing secret via injected storage', () async {
      await store.write('ref_x', 'first_val');
      await store.write('ref_x', 'second_val');
      final result = await store.read('ref_x');
      expect(result, equals('second_val'));
    });

    test('deletes secret via injected storage', () async {
      await store.write('ref_y', 'val_y');
      await store.delete('ref_y');
      final result = await store.read('ref_y');
      expect(result, isNull);
    });

    test('deleting one key leaves others intact (isolation)', () async {
      await store.write('key_1', 'val_1');
      await store.write('key_2', 'val_2');

      await store.delete('key_1');

      expect(await store.read('key_1'), isNull);
      expect(await store.read('key_2'), equals('val_2'));
    });
  });
}
