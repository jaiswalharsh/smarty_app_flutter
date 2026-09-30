// The account's toys (parents/{uid}/devices): how a freshly installed app
// recognises the parent's own Smarty by its Bluetooth name before connecting.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/home_tab.dart'
    show reconnectOfferLine, reconnectOfferLineFor;
import 'package:smarty_app/services/device_registration_service.dart';
import 'package:smarty_app/services/known_toys_service.dart';

void main() {
  group('bleNameFromDeviceId', () {
    test("the owner's toy: 1cc3abc9b11c → Smarty-B11E (Bluetooth = base + 2)",
        () {
      expect(bleNameFromDeviceId('1cc3abc9b11c'), 'Smarty-B11E');
    });

    test('uppercase or padded ids work the same', () {
      expect(bleNameFromDeviceId('1CC3ABC9B11C'), 'Smarty-B11E');
      expect(bleNameFromDeviceId(' 1cc3abc9b11c\n'), 'Smarty-B11E');
    });

    test('the last byte wraps with no carry into the byte before it '
        '(ESP-IDF adds 2 to mac[5] only)', () {
      expect(bleNameFromDeviceId('1cc3abc9b1fd'), 'Smarty-B1FF');
      expect(bleNameFromDeviceId('1cc3abc9b1fe'), 'Smarty-B100');
      expect(bleNameFromDeviceId('1cc3abc9b1ff'), 'Smarty-B101');
      expect(bleNameFromDeviceId('1cc3abc9fffe'), 'Smarty-FF00');
      expect(bleNameFromDeviceId('000000000000'), 'Smarty-0002');
    });

    test('anything but 12 hex characters → null', () {
      for (final id in [
        '',
        '1cc3abc9b11',
        '1cc3abc9b11c0',
        '1cc3abc9b11g',
        '1c:c3:ab:c9:b1:1c',
        '{}',
      ]) {
        expect(bleNameFromDeviceId(id), isNull, reason: id);
      }
    });
  });

  group('normalizeBleName', () {
    test("the firmware's spelling, whatever the case", () {
      expect(normalizeBleName('Smarty-B11E'), 'Smarty-B11E');
      expect(normalizeBleName('smarty-b11e'), 'Smarty-B11E');
      expect(normalizeBleName('  SMARTY-b11e '), 'Smarty-B11E');
    });

    test('not a toy name → null', () {
      for (final raw in [
        null,
        '',
        'Smarty',
        'Smarty-B11',
        'Smarty-B11E1',
        'Smarty B11E',
        'Smarty_B11E',
        'Smarty-G11E',
        'iPhone',
      ]) {
        expect(normalizeBleName(raw), isNull, reason: '$raw');
      }
    });
  });

  group('knownToyFromRecord', () {
    test('the stored ble_name wins', () {
      expect(
        knownToyFromRecord('1cc3abc9b11c', {'ble_name': 'Smarty-ABCD'}),
        const KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-ABCD'),
      );
      expect(
        knownToyFromRecord('1cc3abc9b11c', {'ble_name': 'smarty-abcd'})
            .bleName,
        'Smarty-ABCD',
      );
    });

    test('no (usable) ble_name → worked out from the id', () {
      for (final data in <Map<String, dynamic>>[
        {},
        {'ble_name': null},
        {'ble_name': 42},
        {'ble_name': 'Smarty'},
        {'ble_name': 'not a name'},
      ]) {
        expect(knownToyFromRecord('1cc3abc9b11c', data).bleName,
            'Smarty-B11E',
            reason: '$data');
      }
    });

    test('an id that is not a MAC and no stored name → no name', () {
      expect(knownToyFromRecord('some-dev-id', {}).bleName, isNull);
    });
  });

  group('KnownToy.matchesName', () {
    const toy = KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E');

    test('its own name, whatever the case and spacing', () {
      expect(toy.matchesName('Smarty-B11E'), isTrue);
      expect(toy.matchesName('smarty-b11e'), isTrue);
      expect(toy.matchesName(' Smarty-B11E '), isTrue);
    });

    test('another toy, no name, or a toy with no known name → no match', () {
      expect(toy.matchesName('Smarty-B11F'), isFalse);
      expect(toy.matchesName(''), isFalse);
      expect(toy.matchesName(null), isFalse);
      expect(
          const KnownToy(deviceId: 'x').matchesName('Smarty-B11E'), isFalse);
    });
  });

  group('released toys ("I don\'t have this Smarty any more", chats kept)',
      () {
    test('isReleasedRecord: only released: true', () {
      expect(isReleasedRecord({'released': true}), isTrue);
      for (final data in <Map<String, dynamic>>[
        {},
        {'released': false},
        {'released': 'true'},
        {'released': null},
      ]) {
        expect(isReleasedRecord(data), isFalse, reason: '$data');
      }
    });

    test('knownToysFromRecords leaves them out, keeps the order', () {
      expect(
        knownToysFromRecords([
          ('1cc3abc9b11c', <String, dynamic>{}),
          ('0a0b0c0d0e0f', <String, dynamic>{'released': true}),
          ('aabbccddeeff', <String, dynamic>{'ble_name': 'Smarty-1234'}),
        ]),
        const [
          KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
          KnownToy(deviceId: 'aabbccddeeff', bleName: 'Smarty-1234'),
        ],
      );
    });

    test('the service never lists them', () async {
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) async => (
          records: [
            ('0a0b0c0d0e0f', <String, dynamic>{
              'released': true,
              'device_id': '0a0b0c0d0e0f',
            }),
            ('1cc3abc9b11c', <String, dynamic>{'ble_name': 'Smarty-B11E'}),
          ],
          fromCache: false,
        ),
      );
      expect(await s.knownToysForAccount(), const [
        KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
      ]);
    });

    test('only released ones → none (a plain setup is offered)', () async {
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) async => (
          records: [
            ('0a0b0c0d0e0f', <String, dynamic>{'released': true}),
          ],
          fromCache: false,
        ),
      );
      expect(await s.knownToysForAccount(), isEmpty);
    });
  });

  group('KnownToysService', () {
    ToyRecords records(List<String> ids, {bool fromCache = false}) => (
          records: [for (final id in ids) (id, <String, dynamic>{})],
          fromCache: fromCache,
        );

    test('signed out → none, without reading', () async {
      int reads = 0;
      final s = KnownToysService(
        currentUid: () => null,
        read: (_) async {
          reads++;
          return records(['1cc3abc9b11c']);
        },
      );
      expect(await s.knownToysForAccount(), isEmpty);
      expect(reads, 0);
    });

    test('Firebase not available → none (no throw)', () async {
      final s = KnownToysService(
        currentUid: () => throw StateError('no Firebase'),
      );
      expect(await s.knownToysForAccount(), isEmpty);
    });

    test('reads the records once per account, in order, names worked out',
        () async {
      final reads = <String>[];
      String uid = 'parent-a';
      final s = KnownToysService(
        currentUid: () => uid,
        read: (u) async {
          reads.add(u);
          return (
            records: [
              ('1cc3abc9b11c', <String, dynamic>{}),
              ('0a0b0c0d0e0f', <String, dynamic>{'ble_name': 'Smarty-0E11'}),
            ],
            fromCache: false,
          );
        },
      );
      final first = await s.knownToysForAccount();
      expect(first, const [
        KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
        KnownToy(deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-0E11'),
      ]);
      expect(await s.knownToysForAccount(), first);
      expect(reads, ['parent-a']);

      // Another account reads its own.
      uid = 'parent-b';
      await s.knownToysForAccount();
      expect(reads, ['parent-a', 'parent-b']);
    });

    test('two asks at once share one read', () async {
      int reads = 0;
      final gate = Completer<ToyRecords>();
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) {
          reads++;
          return gate.future;
        },
      );
      final a = s.knownToysForAccount();
      final b = s.knownToysForAccount();
      gate.complete(records(['1cc3abc9b11c']));
      expect(await a, hasLength(1));
      expect(await b, hasLength(1));
      expect(reads, 1);
    });

    test('slow (past the timeout) → none, and asked again next time',
        () async {
      int reads = 0;
      final s = KnownToysService(
        currentUid: () => 'p',
        timeout: const Duration(milliseconds: 20),
        read: (_) {
          reads++;
          return reads == 1
              ? Completer<ToyRecords>().future // never answers
              : Future.value(records(['1cc3abc9b11c']));
        },
      );
      expect(await s.knownToysForAccount(), isEmpty);
      expect(await s.knownToysForAccount(), hasLength(1));
      expect(reads, 2);
    });

    test('an error → none, and asked again next time', () async {
      int reads = 0;
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) async {
          reads++;
          if (reads == 1) throw Exception('permission-denied');
          return records(['1cc3abc9b11c']);
        },
      );
      expect(await s.knownToysForAccount(), isEmpty);
      expect(await s.knownToysForAccount(), hasLength(1));
    });

    test("an empty answer from the phone's offline copy isn't kept; a "
        'non-empty one is', () async {
      int reads = 0;
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) async {
          reads++;
          return reads == 1
              ? records([], fromCache: true)
              : records(['1cc3abc9b11c'], fromCache: true);
        },
      );
      expect(await s.knownToysForAccount(), isEmpty);
      expect(await s.knownToysForAccount(), hasLength(1));
      expect(await s.knownToysForAccount(), hasLength(1));
      expect(reads, 2);
    });

    test('forgetCachedToys (a toy was just linked) → read again; a read '
        'started before it is not kept', () async {
      final answers = <Completer<ToyRecords>>[];
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) {
          final c = Completer<ToyRecords>();
          answers.add(c);
          return c.future;
        },
      );
      final before = s.knownToysForAccount();
      s.forgetCachedToys();
      answers[0].complete(records([]));
      expect(await before, isEmpty);
      final after = s.knownToysForAccount();
      expect(answers, hasLength(2)); // the old answer wasn't kept
      answers[1].complete(records(['1cc3abc9b11c']));
      expect(await after, hasLength(1));
    });

    test('Forget holds back the Reconnect offer for this account only',
        () {
      String uid = 'parent-a';
      final s = KnownToysService(currentUid: () => uid);
      expect(s.offerReconnect, isTrue);
      s.holdBackReconnectOffer();
      expect(s.offerReconnect, isFalse);
      uid = 'parent-b'; // another account signs in
      expect(s.offerReconnect, isTrue);
      uid = 'parent-a';
      expect(s.offerReconnect, isFalse);
      s.debugReset(); // = the next app launch
      expect(s.offerReconnect, isTrue);
    });
  });

  group('registerDevice body', () {
    test('sends the toy name when it is one', () {
      expect(
        DeviceRegistrationService.registerBody('1cc3abc9b11c',
            bleName: 'Smarty-B11E'),
        {'device_id': '1cc3abc9b11c', 'ble_name': 'Smarty-B11E'},
      );
      expect(
        DeviceRegistrationService.registerBody('1cc3abc9b11c',
            bleName: 'smarty-b11e'),
        {'device_id': '1cc3abc9b11c', 'ble_name': 'Smarty-B11E'},
      );
    });

    test('no name, or not a toy name → just the id', () {
      for (final name in [null, '', 'Smarty', 'iPhone']) {
        expect(
          DeviceRegistrationService.registerBody('1cc3abc9b11c',
              bleName: name),
          {'device_id': '1cc3abc9b11c'},
          reason: '$name',
        );
      }
    });
  });

  group('still linked to another family (registerDevice 409)', () {
    test('what to do, with the toy\'s code', () {
      expect(ownedElsewhereHeading,
          'This Smarty is still linked to another family.');
      expect(
        ownedElsewhereMessage('smarty-b11e'),
        'Ask them to open the Smarty app → Home → ⋯ → Remove from my '
        "account. If you can't reach them, contact office@hey-smarty.com "
        'with the code on the toy (Smarty-B11E).',
      );
    });

    test('code not known → the placeholder', () {
      expect(ownedElsewhereMessage(null), endsWith('(Smarty-XXXX).'));
      expect(RegistrationFailure.alreadyOwned.message,
          ownedElsewhereMessage(null));
      expect(RegistrationFailure.alreadyOwned.canRetry, isFalse);
    });
  });

  group('reconnectOfferLine', () {
    test('names the toy as it shows over Bluetooth', () {
      expect(reconnectOfferLine('Smarty-B11E'),
          'You set up Smarty-B11E on this account before.');
    });

    test('several toys: how many', () {
      expect(
          reconnectOfferLineFor(const [
            KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
            KnownToy(deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-0E11'),
          ]),
          'You set up 2 Smarty toys on this account before.');
      expect(
          reconnectOfferLineFor(const [
            KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
          ]),
          'You set up Smarty-B11E on this account before.');
    });

    test('no usable name → "a Smarty"', () {
      expect(reconnectOfferLine(null),
          'You set up a Smarty on this account before.');
      expect(reconnectOfferLine('weird'),
          'You set up a Smarty on this account before.');
    });
  });

  group('claim keys (device_secret_hash)', () {
    const keyA =
        '6c86c6aac5fb24bcf5d9939cb7d7d5645ce39418f449e03b262dd4fa14b4b92b';
    const keyB =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    test('read along with the name; a malformed one is left out', () {
      expect(
        knownToyFromRecord('1cc3abc9b11c', {'device_secret_hash': keyA}),
        const KnownToy(
            deviceId: '1cc3abc9b11c',
            bleName: 'Smarty-B11E',
            deviceSecretHash: keyA),
      );
      for (final bad in [null, '', 'nope', keyA.toUpperCase(), 42]) {
        expect(
            knownToyFromRecord('1cc3abc9b11c', {'device_secret_hash': bad})
                .deviceSecretHash,
            isNull,
            reason: '$bad');
      }
    });

    test('kept per account and toy', () {
      expect(claimKeyPrefsKey('parent-a', '1cc3abc9b11c'),
          'toy_claim_key_parent-a_1cc3abc9b11c');
      expect(claimKeyPrefsKey('parent-a', '1cc3abc9b11c'),
          startsWith(claimKeyPrefsPrefix('parent-a')));
      expect(claimKeyPrefsKey('parent-b', '1cc3abc9b11c'),
          isNot(startsWith(claimKeyPrefsPrefix('parent-a'))));
    });

    test('claimKeyAmong: by id, else by name', () {
      const toys = [
        KnownToy(
            deviceId: '1cc3abc9b11c',
            bleName: 'Smarty-B11E',
            deviceSecretHash: keyA),
        KnownToy(deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-0E11'),
      ];
      expect(claimKeyAmong(toys, deviceId: '1cc3abc9b11c'), keyA);
      expect(claimKeyAmong(toys, bleName: 'smarty-b11e'), keyA);
      // Its id wins over a name.
      expect(
          claimKeyAmong(toys, deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-B11E'),
          isNull);
      expect(claimKeyAmong(toys, bleName: 'Smarty-0E11'), isNull); // no key
      expect(claimKeyAmong(toys, bleName: 'Smarty-FFFF'), isNull);
      expect(claimKeyAmong(toys), isNull);
    });

    test('kept keys can be found by the name worked out from the id', () {
      final toys = knownToysFromClaimKeys(
          {'1cc3abc9b11c': keyA, '0a0b0c0d0e0f': 'broken'});
      expect(toys, const [
        KnownToy(
            deviceId: '1cc3abc9b11c',
            bleName: 'Smarty-B11E',
            deviceSecretHash: keyA),
      ]);
      expect(claimKeyAmong(toys, bleName: 'Smarty-B11E'), keyA);
    });

    test('claimKeyCacheChanges: new and changed keys are written; keys of '
        'toys gone from the account are dropped only on our server\'s word',
        () {
      const toys = [
        KnownToy(deviceId: '1cc3abc9b11c', deviceSecretHash: keyB),
        KnownToy(deviceId: '0a0b0c0d0e0f', deviceSecretHash: keyA),
        KnownToy(deviceId: '111111111111'), // no key
      ];
      final kept = {
        '1cc3abc9b11c': keyA, // linked again since: new key
        '0a0b0c0d0e0f': keyA, // unchanged
        '222222222222': keyA, // removed from the account
      };
      expect(
        claimKeyCacheChanges(kept: kept, toys: toys, authoritative: true),
        {'1cc3abc9b11c': keyB, '222222222222': null},
      );
      // The phone's offline copy may just not know the record: keep it.
      expect(
        claimKeyCacheChanges(kept: kept, toys: toys, authoritative: false),
        {'1cc3abc9b11c': keyB},
      );
      expect(
        claimKeyCacheChanges(kept: const {}, toys: const [], authoritative: true),
        isEmpty,
      );
    });

    group('KnownToysService', () {
      late int reads;
      late Map<String, dynamic> record;

      KnownToysService service({String? uid = 'parent-a'}) {
        reads = 0;
        return KnownToysService(
          currentUid: () => uid,
          read: (_) async {
            reads++;
            return (
              records: [('1cc3abc9b11c', record)],
              fromCache: false,
            );
          },
        );
      }

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        record = {'device_secret_hash': keyA};
      });

      Future<Map<String, Object>> kept() async {
        final prefs = await SharedPreferences.getInstance();
        return {
          for (final k in prefs.getKeys())
            if (k.startsWith('toy_claim_key_')) k: prefs.get(k)!,
        };
      }

      test('reading the account\'s toys keeps their keys on the phone',
          () async {
        final s = service();
        await s.knownToysForAccount();
        await pumpEventQueue();
        expect(await kept(), {'toy_claim_key_parent-a_1cc3abc9b11c': keyA});
      });

      test('the phone\'s key first (works offline); else the account\'s '
          'records, then kept', () async {
        SharedPreferences.setMockInitialValues({
          'toy_claim_key_parent-a_1cc3abc9b11c': keyB,
        });
        final s = service();
        expect(await s.claimKeyFor(bleName: 'Smarty-B11E'), keyB);
        expect(await s.claimKeyFor(deviceId: '1cc3abc9b11c'), keyB);
        expect(reads, 0);

        SharedPreferences.setMockInitialValues({});
        final fresh = service();
        expect(await fresh.claimKeyFor(bleName: 'Smarty-B11E'), keyA);
        expect(reads, 1);
        await pumpEventQueue();
        expect(await kept(), {'toy_claim_key_parent-a_1cc3abc9b11c': keyA});
      });

      test('not the account\'s toy, no key, or signed out → null', () async {
        record = {};
        final s = service();
        expect(await s.claimKeyFor(bleName: 'Smarty-B11E'), isNull);
        expect(await s.claimKeyFor(bleName: 'Smarty-FFFF'), isNull);
        expect(await s.claimKeyFor(), isNull);
        expect(await service(uid: null).claimKeyFor(bleName: 'Smarty-B11E'),
            isNull);
      });

      test('the phone that links a toy keeps its new key (no cloud needed)',
          () async {
        final s = service();
        await s.rememberClaimKey('1cc3abc9b11c', keyB);
        await s.rememberClaimKey('0a0b0c0d0e0f', 'not a key');
        expect(await kept(), {'toy_claim_key_parent-a_1cc3abc9b11c': keyB});
        expect(await s.claimKeyFor(bleName: 'Smarty-B11E'), keyB);
        expect(reads, 0);
      });

      test('a turned-down key is dropped (by id, or by name) and the '
          'records are read afresh next time', () async {
        SharedPreferences.setMockInitialValues({
          'toy_claim_key_parent-a_1cc3abc9b11c': keyB,
          'toy_claim_key_parent-a_0a0b0c0d0e0f': keyB,
          'toy_claim_key_parent-b_1cc3abc9b11c': keyB,
        });
        final s = service();
        await s.forgetClaimKey(bleName: 'Smarty-B11E');
        expect(await kept(), {
          'toy_claim_key_parent-a_0a0b0c0d0e0f': keyB,
          'toy_claim_key_parent-b_1cc3abc9b11c': keyB,
        });
        await s.forgetClaimKey(deviceId: '0a0b0c0d0e0f');
        expect(await kept(), {'toy_claim_key_parent-b_1cc3abc9b11c': keyB});
        expect(await s.claimKeyFor(bleName: 'Smarty-B11E'), keyA);
        expect(reads, 1);
      });

      test('sign-out / account deleted: every key of that account goes',
          () async {
        SharedPreferences.setMockInitialValues({
          'toy_claim_key_parent-a_1cc3abc9b11c': keyA,
          'toy_claim_key_parent-a_0a0b0c0d0e0f': 'broken',
          'toy_claim_key_parent-b_1cc3abc9b11c': keyB,
          'smarty_saved_device_id_parent-a': 'AA:BB',
        });
        await KnownToysService.clearClaimKeys('parent-a');
        expect(await kept(), {'toy_claim_key_parent-b_1cc3abc9b11c': keyB});
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('smarty_saved_device_id_parent-a'), 'AA:BB');
      });
    });
  });
}
