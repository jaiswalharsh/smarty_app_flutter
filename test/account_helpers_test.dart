// Pure logic behind the "Your account" page: avatar initials, name checks,
// error wording, and which saved data belongs to an account.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/screens/account/account_helpers.dart';
import 'package:smarty_app/services/account_service.dart';

void main() {
  group('initialsFor', () {
    test('first and last word of the name', () {
      expect(initialsFor(displayName: 'Anna Maria Kowalska'), 'AK');
      expect(initialsFor(displayName: '  harsh   jaiswal '), 'HJ');
    });

    test('single-word name gives one letter', () {
      expect(initialsFor(displayName: 'anna'), 'A');
    });

    test('name wins over email', () {
      expect(
        initialsFor(displayName: 'Ola', email: 'john.doe@example.com'),
        'O',
      );
    });

    test('falls back to the email before the @', () {
      expect(initialsFor(email: 'john.doe@example.com'), 'JD');
      expect(initialsFor(email: 'mary_ann-smith@example.com'), 'MS');
      expect(initialsFor(email: 'parent+smarty@example.com'), 'PS');
      expect(initialsFor(email: 'kasia@example.com'), 'K');
    });

    test('blank name falls back to the email', () {
      expect(initialsFor(displayName: '   ', email: 'kasia@example.com'), 'K');
    });

    test('skips leading symbols and keeps non-English letters', () {
      expect(initialsFor(displayName: '(Łukasz) Żak'), 'ŁŻ');
      expect(initialsFor(email: '_zoe@example.com'), 'Z');
    });

    test('empty when there is nothing usable', () {
      expect(initialsFor(), '');
      expect(initialsFor(displayName: '', email: ''), '');
      expect(initialsFor(email: '...@example.com'), '');
    });
  });

  group('display name', () {
    test('normalize trims and collapses spaces', () {
      expect(normalizeDisplayName('  Anna   Maria  '), 'Anna Maria');
    });

    test('empty name is refused', () {
      expect(validateDisplayName(''), 'Please type your name.');
      expect(validateDisplayName('    '), 'Please type your name.');
    });

    test('up to the limit is fine, past it is refused', () {
      expect(validateDisplayName('a' * maxDisplayNameLength), isNull);
      expect(validateDisplayName('  ${'a' * maxDisplayNameLength}  '), isNull);
      expect(validateDisplayName('a' * (maxDisplayNameLength + 1)),
          contains('$maxDisplayNameLength letters'));
    });

    test('counts letters, not bytes', () {
      expect(validateDisplayName('ż' * maxDisplayNameLength), isNull);
    });
  });

  group('account problems', () {
    test('error codes map to plain problems', () {
      expect(accountProblemFromCode('wrong-password'),
          AccountProblem.wrongPassword);
      expect(accountProblemFromCode('invalid-credential'),
          AccountProblem.wrongPassword);
      expect(accountProblemFromCode('network-request-failed'),
          AccountProblem.network);
      expect(accountProblemFromCode('too-many-requests'),
          AccountProblem.tooManyRequests);
      expect(accountProblemFromCode('requires-recent-login'),
          AccountProblem.signInAgain);
      expect(accountProblemFromCode('something-new'), AccountProblem.other);
    });

    test('messages are plain language', () {
      expect(accountProblemMessage(AccountProblem.wrongPassword),
          "That password isn't right.");
      for (final p in AccountProblem.values) {
        final m = accountProblemMessage(p).toLowerCase();
        for (final word in ['firebase', 'uid', 'credential', 'authenticat']) {
          expect(m, isNot(contains(word)), reason: '$p: $m');
        }
      }
    });
  });

  group('local account data', () {
    test('lists every per-account key', () {
      expect(
        localAccountDataKeys('u1'),
        unorderedEquals([
          'smarty_saved_device_id_u1',
          'smarty_saved_device_name_u1',
          'smarty_last_wifi_u1',
          'user_context_u1',
          'user_context_pending_sync_u1',
        ]),
      );
    });

    test('clearing removes only that account\'s keys — its toys\' claim keys '
        'too', () async {
      SharedPreferences.setMockInitialValues({
        'smarty_saved_device_id_u1': 'AA:BB',
        'smarty_saved_device_name_u1': 'Smarty-1234',
        'smarty_last_wifi_u1': 'Home',
        'user_context_u1': '{"name":"Zosia"}',
        'user_context_pending_sync_u1': true,
        'toy_claim_key_u1_1cc3abc9b11c': 'a' * 64,
        'smarty_saved_device_id_u2': 'CC:DD',
        'user_context_u2': '{"name":"Jan"}',
        'toy_claim_key_u2_1cc3abc9b11c': 'b' * 64,
        'theme_mode': 'dark',
      });
      await clearLocalAccountData('u1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        'smarty_saved_device_id_u2',
        'user_context_u2',
        'toy_claim_key_u2_1cc3abc9b11c',
        'theme_mode',
      });
    });
  });
}
