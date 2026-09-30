import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/services/toy_claim.dart';

void main() {
  group('BleManager.classifyConnectError', () {
    ConnectFailure classify(Object e) => BleManager.classifyConnectError(e);

    test('iOS "peer removed pairing information" is pairingBroken', () {
      expect(classify(Exception('Peer removed pairing information')),
          ConnectFailure.pairingBroken);
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple, 'connect', 14,
              'Peer removed pairing information')),
          ConnectFailure.pairingBroken);
    });

    test('GATT 5 / 8 / 15 on a read/write/notify is pairingBroken', () {
      for (final code in [5, 8, 15]) {
        expect(
            classify(FlutterBluePlusException(
                ErrorPlatform.android, 'setNotifyValue', code, 'GATT error')),
            ConnectFailure.pairingBroken,
            reason: 'GATT $code');
      }
      expect(
          classify(Exception(
              'readCharacteristic: GATT_INSUFFICIENT_AUTHENTICATION')),
          ConnectFailure.pairingBroken);
    });

    test('permission errors need permission', () {
      expect(classify(Exception('Bluetooth permission denied')),
          ConnectFailure.needsPermission);
      expect(
          classify(PlatformException(
              code: 'startScan', message: 'no permissions for scanning')),
          ConnectFailure.needsPermission);
    });

    test('cancellations are cancelledByUser', () {
      expect(classify(Exception('Connection cancelled')),
          ConnectFailure.cancelledByUser);
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.fbp, 'connect',
              FbpErrorCode.connectionCanceled.index, 'connection canceled')),
          ConnectFailure.cancelledByUser);
    });

    test('timeouts and Android 133 are outOfRange', () {
      expect(classify(TimeoutException('connect')), ConnectFailure.outOfRange);
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.fbp, 'connect',
              FbpErrorCode.timeout.index, 'Timed out after 10s')),
          ConnectFailure.outOfRange);
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.android, 'connect',
              133, 'ANDROID_SPECIFIC_ERROR')),
          ConnectFailure.outOfRange);
      expect(classify(Exception('Device not found')), ConnectFailure.outOfRange);
    });

    test('a missing service is notSmarty', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.fbp, 'discover',
              FbpErrorCode.serviceNotFound.index, 'service not found')),
          ConnectFailure.notSmarty);
      expect(classify(Exception('Smarty service not found')),
          ConnectFailure.notSmarty);
      expect(classify(const ConnectException(ConnectFailure.notSmarty)),
          ConnectFailure.notSmarty);
    });

    test('Bluetooth off', () {
      expect(classify(Exception('Bluetooth must be turned on')),
          ConnectFailure.bluetoothOff);
    });

    test('anything else is unknown', () {
      expect(classify(Exception('something odd happened')),
          ConnectFailure.unknown);
      expect(classify(StateError('Link dropped during setup')),
          ConnectFailure.unknown);
    });
  });

  group('toy names', () {
    test('toyDisplayName', () {
      expect(BleManager.toyDisplayName('Smarty-AB12'), 'Smarty');
      expect(BleManager.toyDisplayName('Smarty'), 'Smarty');
      expect(BleManager.toyDisplayName(null), 'Smarty');
      expect(BleManager.toyDisplayName('  '), 'Smarty');
    });

    test('toyCode', () {
      expect(BleManager.toyCode('Smarty-AB12'), 'AB12');
      expect(BleManager.toyCode('smarty-ab12'), 'AB12');
      expect(BleManager.toyCode('Smarty'), isNull);
      expect(BleManager.toyCode(null), isNull);
    });
  });

  group('ToyStatus.parse', () {
    test('legacy read value "BAT:90,WIFI:Wifi0460"', () {
      final st = ToyStatus.parse('BAT:90,WIFI:Wifi0460')!;
      expect(st.wifi, 'Wifi0460');
      expect(st.battery, 90);
      expect(st.registered, isNull);
      expect(BleManager.isWifiConnectedStatus(st.wifi!), isTrue);
    });

    test('legacy value with a status token', () {
      expect(ToyStatus.parse('BAT:0,WIFI:Unknown')!.wifi, 'Unknown');
      expect(ToyStatus.parse('BAT:90,WIFI:No credentials')!.wifi,
          'No credentials');
      expect(ToyStatus.parse('BAT:90,WIFI:Auth Failed')!.wifi, 'Auth Failed');
    });

    test('legacy value: the network name runs to the end', () {
      final st = ToyStatus.parse('BAT:75,WIFI:Cafe: 2,4 GHz')!;
      expect(st.wifi, 'Cafe: 2,4 GHz');
      expect(st.battery, 75);
    });

    test('legacy value in the other order', () {
      final st = ToyStatus.parse('WIFI:HomeNet,BAT:42')!;
      expect(st.wifi, 'HomeNet');
      expect(st.battery, 42);
    });

    test('JSON (notification, and reads on new firmware)', () {
      final st = ToyStatus.parse('{"version":"1.0","battery":90,'
          '"wifi":"Wifi0460","registered":false,'
          '"system":{"device_name":"Smarty-1A2B"}}')!;
      expect(st.wifi, 'Wifi0460');
      expect(st.battery, 90);
      expect(st.registered, isFalse);
    });

    test('JSON with a token, a double / string battery, no registered', () {
      final a = ToyStatus.parse('{"battery":88.0,"wifi":"Initializing"}')!;
      expect(a.wifi, 'Initializing');
      expect(a.battery, 88);
      expect(a.registered, isNull);
      expect(ToyStatus.parse('{"battery":"77%","wifi":"x"}')!.battery, 77);
    });

    test('the "{}" placeholder carries nothing', () {
      final st = ToyStatus.parse('{}')!;
      expect(st.wifi, isNull);
      expect(st.battery, isNull);
      expect(st.registered, isNull);
    });

    test('broken JSON is ignored, never taken for a network name', () {
      expect(ToyStatus.parse('{"version":"1.0","battery":90,"wi'), isNull);
      expect(ToyStatus.parse('[1,2]'), isNull);
      expect(ToyStatus.parse(''), isNull);
      expect(ToyStatus.parse('   '), isNull);
    });

    test('oldest "name,level" format', () {
      final st = ToyStatus.parse('HomeNet,55')!;
      expect(st.wifi, 'HomeNet');
      expect(st.battery, 55);
      expect(ToyStatus.parse('HomeNet')!.battery, isNull);
    });
  });

  group('isWifiConnectedStatus', () {
    test('status tokens are not a network', () {
      for (final s in [
        '',
        'Unknown',
        'NotConnected',
        'Initializing',
        'Auth Failed',
        'Connection Failed',
        'No credentials',
        'Reconnecting',
      ]) {
        expect(BleManager.isWifiConnectedStatus(s), isFalse, reason: s);
      }
    });

    test('a real network name is connected', () {
      expect(BleManager.isWifiConnectedStatus('HomeNet'), isTrue);
    });
  });

  group('ToyAdvert.fromScanResult', () {
    ScanResult scan(Map<Guid, List<int>> serviceData) => ScanResult(
          device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF'),
          advertisementData: AdvertisementData(
            advName: 'Smarty-AB12',
            txPowerLevel: null,
            appearance: null,
            connectable: true,
            manufacturerData: const {},
            serviceData: serviceData,
            serviceUuids: [Guid('abcd')],
          ),
          rssi: -50,
          timeStamp: DateTime(2026, 9, 26),
        );

    test('no service data (old firmware) → null', () {
      expect(ToyAdvert.fromScanResult(scan(const {})), isNull);
    });

    test('[0x03, 0x01] → pairing, on Wi-Fi, not registered, version 1', () {
      final a = ToyAdvert.fromScanResult(scan({
        Guid('abcd'): [0x03, 0x01],
      }))!;
      expect(a.pairing, isTrue);
      expect(a.wifiUp, isTrue);
      expect(a.registered, isFalse);
      expect(a.version, 1);
      expect(a.isLegacy, isFalse);
    });

    test('the 128-bit base form of 0xABCD is the same key', () {
      expect(Guid('0000abcd-0000-1000-8000-00805f9b34fb'), Guid('abcd'));
      final a = ToyAdvert.fromScanResult(scan({
        Guid('0000abcd-0000-1000-8000-00805f9b34fb'): [0x04, 0x01],
      }))!;
      expect(a, const ToyAdvert(
          pairing: false, wifiUp: false, registered: true, version: 1));
    });

    test('[0x00, 0x00] → nothing set, version 0 (legacy)', () {
      final a = ToyAdvert.fromScanResult(scan({
        Guid('abcd'): [0x00, 0x00],
      }))!;
      expect(a.pairing, isFalse);
      expect(a.wifiUp, isFalse);
      expect(a.registered, isFalse);
      expect(a.version, 0);
      expect(a.isLegacy, isTrue);
    });

    test('a single flags byte means version 0', () {
      final a = ToyAdvert.fromScanResult(scan({
        Guid('abcd'): [0x01],
      }))!;
      expect(a.pairing, isTrue);
      expect(a.version, 0);
    });

    test('reserved bits 3–7 are ignored', () {
      final a = ToyAdvert.fromScanResult(scan({
        Guid('abcd'): [0xF9, 0x01], // 1111 1001
      }))!;
      expect(a, const ToyAdvert(
          pairing: true, wifiUp: false, registered: false, version: 1));
    });

    test('service data under another UUID is ignored', () {
      expect(
          ToyAdvert.fromScanResult(scan({
            Guid('180f'): [0x03, 0x01],
          })),
          isNull);
      final a = ToyAdvert.fromScanResult(scan({
        Guid('180f'): [0x00, 0x00],
        Guid('abcd'): [0x02, 0x01],
      }))!;
      expect(a.pairing, isFalse);
      expect(a.wifiUp, isTrue);
    });

    test('empty data under 0xABCD counts as none', () {
      expect(ToyAdvert.fromScanResult(scan({Guid('abcd'): <int>[]})), isNull);
    });
  });

  group('BleManager.profileMaxBytesFor', () {
    test('no advert data → 500', () {
      expect(BleManager.profileMaxBytesFor(null), 500);
      expect(BleManager.profileMaxBytesFor(null),
          BleManager.userContextMaxBytesLegacy);
    });

    test('version 0 → 500', () {
      expect(BleManager.profileMaxBytesFor(const ToyAdvert(pairing: true)),
          500);
    });

    test('version 1 (and later) → 1024', () {
      expect(
          BleManager.profileMaxBytesFor(
              const ToyAdvert(pairing: true, version: 1)),
          1024);
      expect(BleManager.profileMaxBytesFor(const ToyAdvert(version: 2)), 1024);
    });
  });

  group('BleManager.deriveRegistered', () {
    bool? derive(bool? status, bool? local,
            {bool linked = false, bool? accountHasToy}) =>
        BleManager.deriveRegistered(
          statusRegistered: status,
          localRegistered: local,
          linkedThisConnection: linked,
          accountHasToy: accountHasToy,
        );

    test('status field wins over the local record', () {
      expect(derive(true, false), isTrue);
      expect(derive(false, true), isFalse);
      expect(derive(null, true), isTrue);
      expect(derive(null, false), isFalse);
      expect(derive(null, null), isNull);
    });

    test('a stale registered:false after linking on this connection is ignored',
        () {
      // Older firmware keeps serving its pre-link status JSON after the
      // secret write; Home must not fall back to "Finish setup".
      expect(derive(false, true, linked: true), isTrue);
      expect(derive(false, null, linked: true), isTrue);
      expect(derive(false, false, linked: true), isTrue);
    });

    test('registered:true is still accepted after linking', () {
      expect(derive(true, true, linked: true), isTrue);
      expect(derive(null, null, linked: true), isTrue);
    });

    test('a new connection (flag cleared) trusts the status again', () {
      expect(derive(false, true, linked: false), isFalse);
    });

    test('the toy holds a key but is not on this account → not linked', () {
      // e.g. a key from a dev emulator, another account or a deleted one:
      // Home must offer "Finish setup" and setup must run its link step.
      expect(derive(true, null, accountHasToy: false), isFalse);
      expect(derive(null, true, accountHasToy: false), isFalse);
      expect(derive(true, true, accountHasToy: false), isFalse);
      expect(derive(null, null, accountHasToy: false), isFalse);
    });

    test("can't tell (offline / signed out) keeps the toy's answer", () {
      expect(derive(true, null, accountHasToy: null), isTrue);
      expect(derive(false, null, accountHasToy: null), isFalse);
      expect(derive(null, true, accountHasToy: null), isTrue);
      expect(derive(null, null, accountHasToy: null), isNull);
    });

    test('on this account: the toy still decides (a lost key needs linking)',
        () {
      expect(derive(true, null, accountHasToy: true), isTrue);
      expect(derive(false, null, accountHasToy: true), isFalse);
      expect(derive(null, true, accountHasToy: true), isTrue);
    });

    test('linking on this connection wins over a "not on this account"', () {
      // The check may have answered before the link finished.
      expect(derive(true, null, linked: true, accountHasToy: false), isTrue);
      expect(derive(false, false, linked: true, accountHasToy: false), isTrue);
    });
  });

  group('BleManager.shouldStartAccountCheck', () {
    bool should({
      bool linkingEnabled = true,
      bool? registered = true,
      bool linked = false,
      bool checked = false,
      bool unknown = false,
      bool retry = false,
    }) =>
        BleManager.shouldStartAccountCheck(
          linkingEnabled: linkingEnabled,
          registered: registered,
          linkedThisConnection: linked,
          checkedThisConnection: checked,
          lastAnswerUnknown: unknown,
          retryUnknown: retry,
        );

    test('a toy that says it is linked is checked once per connection', () {
      expect(should(), isTrue);
      expect(should(checked: true), isFalse);
      expect(should(checked: true, retry: true), isFalse); // it answered
    });

    test("an earlier \"can't tell\" is retried only when asked", () {
      expect(should(checked: true, unknown: true), isFalse);
      expect(should(checked: true, unknown: true, retry: true), isTrue);
    });

    test('nothing to check for a toy that is not (known to be) linked', () {
      expect(should(registered: false), isFalse);
      expect(should(registered: null), isFalse);
    });

    test('not after linking it on this connection', () {
      expect(should(linked: true), isFalse);
    });

    test('never without the account link (dev builds)', () {
      expect(should(linkingEnabled: false), isFalse);
      expect(should(linkingEnabled: false, retry: true, unknown: true,
              checked: true),
          isFalse);
    });
  });

  group('BleManager.isStaleBondEvidence', () {
    bool stale(Object? e, [DisconnectReason? r]) =>
        BleManager.isStaleBondEvidence(e, r);

    test('iOS "peer removed pairing information" (connect error 14) — this '
        "phone's pairing is stale", () {
      expect(
          stale(FlutterBluePlusException(ErrorPlatform.apple, 'connect', 14,
              'Peer removed pairing information')),
          isTrue);
      expect(stale(Exception('Peer removed pairing information')), isTrue);
      expect(stale(null, DisconnectReason(ErrorPlatform.apple, 14, null)),
          isTrue);
    });

    test('Android: our keys rejected (HCI 6 / 0x3D, PIN_OR_KEY_MISSING)', () {
      for (final code in [0x06, 0x3D]) {
        expect(
            stale(FlutterBluePlusException(
                ErrorPlatform.android, 'connect', code, 'hci')),
            isTrue,
            reason: 'HCI $code');
        expect(stale(null, DisconnectReason(ErrorPlatform.android, code, null)),
            isTrue,
            reason: 'reason $code');
      }
      expect(
          stale(PlatformException(
              code: 'connect', message: 'GATT_PIN_OR_KEY_MISSING')),
          isTrue);
    });

    test('a refused NEW pairing is not a stale one (a toy set up with '
        'another phone looks like this)', () {
      // ATT insufficient authentication / encryption on the first subscribe.
      for (final code in [5, 8, 15]) {
        expect(
            stale(FlutterBluePlusException(ErrorPlatform.apple,
                'setNotifyValue', code, 'Authentication is insufficient.')),
            isFalse,
            reason: 'ATT $code');
        expect(
            stale(FlutterBluePlusException(ErrorPlatform.android,
                'setNotifyValue', code, 'GATT_INSUFFICIENT_AUTHENTICATION')),
            isFalse,
            reason: 'GATT $code');
      }
      // Android HCI 5 (authentication failure): the toy's stack ends a
      // refused new pairing with it too.
      expect(
          stale(FlutterBluePlusException(
              ErrorPlatform.android, 'connect', 0x05, 'hci')),
          isFalse);
      expect(stale(null, DisconnectReason(ErrorPlatform.android, 0x05, null)),
          isFalse);
      // iOS encryption timed out (15): could be either.
      expect(
          stale(FlutterBluePlusException(
              ErrorPlatform.apple, 'connect', 15, 'Encryption timed out')),
          isFalse);
      // A link that simply dropped.
      expect(stale(StateError('Link dropped during setup'),
              DisconnectReason(ErrorPlatform.apple, 7, 'disconnected')),
          isFalse);
      expect(stale(null, DisconnectReason(ErrorPlatform.android, 0x13,
              'REMOTE_USER_TERMINATED_CONNECTION')),
          isFalse);
      expect(stale(null), isFalse);
    });

    test('ConnectException carries it (off by default)', () {
      const plain = ConnectException(ConnectFailure.pairingBroken);
      expect(plain.staleBond, isFalse);
      expect(stale(plain), isFalse);
      const marked = ConnectException(ConnectFailure.pairingBroken, null, true);
      expect(marked.staleBond, isTrue);
      expect(stale(marked), isTrue);
      expect(
          stale(ConnectException(ConnectFailure.pairingBroken,
              Exception('Peer removed pairing information'))),
          isTrue);
    });
  });

  group('the claim (proving the account to the toy)', () {
    // Verified in Node (registerDevice) and in the toy's C.
    const secret =
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
    const hash =
        '6c86c6aac5fb24bcf5d9939cb7d7d5645ce39418f449e03b262dd4fa14b4b92b';
    final nonce = List<int>.generate(16, (i) => i);
    const proofHex =
        'b3a802b9a68fda55e785411ad4f06311a250cc9d652baa6a7cafe8f2b0656225';

    String hex(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('claim key = SHA-256 of the secret, lowercase hex (as the backend '
        'stores device_secret_hash)', () {
      expect(claimKeyFromSecret(secret), hash);
      expect(isClaimKey(claimKeyFromSecret(secret)), isTrue);
    });

    test('proof = HMAC-SHA256(key: the 64 hex characters as ASCII, message: '
        'the 16 raw nonce bytes), 32 raw bytes', () {
      final proof = claimProof(hash, nonce);
      expect(proof, hasLength(claimProofLength));
      expect(hex(proof), proofHex);
      // Keyed with the hex text, not with the 32 digest bytes it spells.
      final List<int> digestBytes = [
        for (var i = 0; i < 64; i += 2)
          int.parse(hash.substring(i, i + 2), radix: 16),
      ];
      expect(hex(Hmac(sha256, digestBytes).convert(nonce).bytes),
          isNot(proofHex));
      // A fresh nonce, a different proof.
      expect(hex(claimProof(hash, List<int>.filled(16, 0))), isNot(proofHex));
    });

    test('isClaimKey: 64 lowercase hex only', () {
      expect(isClaimKey(hash), isTrue);
      expect(isClaimKey(hash.toUpperCase()), isFalse);
      expect(isClaimKey(hash.substring(1)), isFalse);
      expect(isClaimKey('${hash}0'), isFalse);
      expect(isClaimKey('g${hash.substring(1)}'), isFalse);
      expect(isClaimKey(null), isFalse);
      expect(isClaimKey(42), isFalse);
      expect(claimNonceLength, 16);
    });

    test('shouldClaim: a toy with the claim characteristic that doesn\'t say '
        'it is unlinked', () {
      expect(
          BleManager.shouldClaim(
              hasClaimCharacteristic: true, advertRegistered: true),
          isTrue);
      // Not seen just before (a background reconnect): prove anyway.
      expect(
          BleManager.shouldClaim(
              hasClaimCharacteristic: true, advertRegistered: null),
          isTrue);
      // Not linked: nobody's account to prove.
      expect(
          BleManager.shouldClaim(
              hasClaimCharacteristic: true, advertRegistered: false),
          isFalse);
      expect(
          BleManager.shouldClaim(
              hasClaimCharacteristic: false, advertRegistered: true),
          isFalse);
    });

    group('claimVerdictFor', () {
      ConnectFailure? verdict(
        ConnectFailure failure, {
        bool linkDown = true,
        Duration? sinceProof,
        bool secured = false,
        bool? registered = true,
      }) =>
          BleManager.claimVerdictFor(
            failure: failure,
            linkDown: linkDown,
            sinceProof: sinceProof,
            secured: secured,
            advertRegistered: registered,
          );

      test('the proof write failed → not this account', () {
        expect(verdict(ConnectFailure.notYourAccount, linkDown: false),
            ConnectFailure.notYourAccount);
      });

      test('the toy hung up right after the proof → not this account '
          '(whatever the failure looked like)', () {
        for (final f in [
          ConnectFailure.unknown,
          ConnectFailure.outOfRange,
          ConnectFailure.pairingBroken,
        ]) {
          expect(verdict(f, sinceProof: const Duration(milliseconds: 200)),
              ConnectFailure.notYourAccount,
              reason: f.name);
          expect(verdict(f, sinceProof: BleManager.claimRejectWindow),
              ConnectFailure.notYourAccount,
              reason: f.name);
        }
      });

      test('a proof that was taken: a later drop is not about it', () {
        expect(
            verdict(ConnectFailure.unknown,
                sinceProof: BleManager.claimRejectWindow +
                    const Duration(milliseconds: 1)),
            isNull);
        // Still up: nothing to say.
        expect(
            verdict(ConnectFailure.unknown,
                linkDown: false, sinceProof: Duration.zero),
            isNull);
      });

      test('a linked toy, no proof, nothing encrypted worked, link gone → a '
          'refused pairing', () {
        expect(verdict(ConnectFailure.unknown), ConnectFailure.pairingBroken);
        expect(
            verdict(ConnectFailure.outOfRange), ConnectFailure.pairingBroken);
      });

      test('…but not when paired, not linked (or not saying), or the failure '
          'already says more', () {
        expect(verdict(ConnectFailure.unknown, secured: true), isNull);
        expect(verdict(ConnectFailure.unknown, registered: false), isNull);
        expect(verdict(ConnectFailure.unknown, registered: null), isNull);
        expect(verdict(ConnectFailure.pairingBroken), isNull);
        expect(verdict(ConnectFailure.unknown, linkDown: false), isNull);
      });

      test('never for a cancel, the Bluetooth states or a toy that isn\'t a '
          'Smarty', () {
        for (final f in [
          ConnectFailure.cancelledByUser,
          ConnectFailure.bluetoothOff,
          ConnectFailure.needsPermission,
          ConnectFailure.notSmarty,
        ]) {
          expect(verdict(f, sinceProof: Duration.zero), isNull,
              reason: f.name);
          expect(verdict(f), isNull, reason: f.name);
        }
      });
    });

    test('notYourAccount is its own failure kind', () {
      expect(
          BleManager.classifyConnectError(
              const ConnectException(ConnectFailure.notYourAccount)),
          ConnectFailure.notYourAccount);
      expect(
          BleManager.isStaleBondEvidence(
              const ConnectException(ConnectFailure.notYourAccount)),
          isFalse);
    });
  });

  group('LinkDropTracker: the toy turning an unproven phone away', () {
    final t0 = DateTime(2026, 9, 30, 12);
    Duration s(int secs) => Duration(seconds: secs);

    test('no proof, never encrypted, dropped 20–60 s after connecting → '
        'turned away (decided at once)', () {
      for (final secs in [20, 30, 45, 60]) {
        final tracker = LinkDropTracker();
        tracker.linkUp(t0);
        expect(tracker.linkDown(t0.add(s(secs))), LinkDropVerdict.turnedAway,
            reason: '$secs s');
      }
    });

    test('a paired link, or one the toy took the proof on, is an ordinary '
        'drop', () {
      final paired = LinkDropTracker()..linkUp(t0);
      paired.linkSecured();
      expect(paired.linkDown(t0.add(s(30))), LinkDropVerdict.normal);

      final proved = LinkDropTracker()..linkUp(t0);
      proved.linkProved();
      expect(proved.linkDown(t0.add(s(30))), LinkDropVerdict.normal);
    });

    test('outside the window: as before', () {
      final early = LinkDropTracker()..linkUp(t0);
      expect(early.linkDown(t0.add(s(10))), LinkDropVerdict.normal);
      final late = LinkDropTracker()..linkUp(t0);
      expect(late.linkDown(t0.add(s(61))), LinkDropVerdict.normal);
      final quick = LinkDropTracker()..linkUp(t0);
      expect(quick.linkDown(t0.add(s(1))), LinkDropVerdict.quick);
    });

    test('ours is ours; the marks belong to one link', () {
      final ours = LinkDropTracker()..linkUp(t0);
      expect(ours.linkDown(t0.add(s(30)), intentional: true),
          LinkDropVerdict.intentional);

      final tracker = LinkDropTracker()..linkUp(t0);
      tracker.linkSecured();
      expect(tracker.linkDown(t0.add(s(5))), LinkDropVerdict.normal);
      // The next link starts unpaired and unproven.
      tracker.linkUp(t0.add(s(10)));
      expect(tracker.linkDown(t0.add(s(40))), LinkDropVerdict.turnedAway);
      // Marks without a link do nothing.
      tracker
        ..linkSecured()
        ..linkProved()
        ..linkUp(t0.add(s(100)));
      expect(tracker.linkDown(t0.add(s(130))), LinkDropVerdict.turnedAway);
    });

    test('turned away breaks a quick-drop streak', () {
      final tracker = LinkDropTracker();
      tracker.linkUp(t0);
      expect(tracker.linkDown(t0.add(s(1))), LinkDropVerdict.quick);
      tracker.linkUp(t0.add(s(2)));
      expect(tracker.linkDown(t0.add(s(32))), LinkDropVerdict.turnedAway);
      expect(tracker.quickDrops, 0);
    });
  });
}
