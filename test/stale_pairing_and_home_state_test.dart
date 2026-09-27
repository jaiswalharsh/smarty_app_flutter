// Stale-pairing detection (classifier strings, disconnect reasons, the
// quick-drop streak) and Home's pure view-state helpers.
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  group('classifyConnectError — exact iOS strings', () {
    ConnectFailure classify(Object e) => BleManager.classifyConnectError(e);

    test('CBError 14 "Peer removed pairing information" (connect)', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple, 'connect', 14,
              'Peer removed pairing information')),
          ConnectFailure.pairingBroken);
    });

    test('CBError 14 on a GATT op (setNotifyValue)', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple,
              'setNotifyValue', 14, 'Peer removed pairing information')),
          ConnectFailure.pairingBroken);
    });

    test('CBATTError 15 "Encryption is insufficient."', () {
      for (final fn in ['setNotifyValue', 'readCharacteristic',
          'writeCharacteristic']) {
        expect(
            classify(FlutterBluePlusException(
                ErrorPlatform.apple, fn, 15, 'Encryption is insufficient.')),
            ConnectFailure.pairingBroken,
            reason: fn);
      }
    });

    test('CBATTError 5 "Authentication is insufficient."', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple,
              'setNotifyValue', 5, 'Authentication is insufficient.')),
          ConnectFailure.pairingBroken);
    });

    test('CBATTError 12 "Encryption key size is insufficient."', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple,
              'setNotifyValue', 12, 'Encryption key size is insufficient.')),
          ConnectFailure.pairingBroken);
    });

    test('the same strings inside a PlatformException', () {
      expect(
          classify(PlatformException(
              code: 'setNotifyValue', message: 'Encryption is insufficient.')),
          ConnectFailure.pairingBroken);
      expect(
          classify(PlatformException(
              code: 'connect', message: 'Peer removed pairing information')),
          ConnectFailure.pairingBroken);
    });

    test('FBP "Device is disconnected" is NOT out of range / pairing', () {
      // The link dropped under a GATT op: the verdict comes from the drop
      // (reason / quick-drop streak), not from this error.
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.fbp,
              'setNotifyValue', FbpErrorCode.deviceIsDisconnected.index,
              'Device is disconnected')),
          ConnectFailure.unknown);
    });

    test('generic iOS disconnects are not pairing errors', () {
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple, 'connect', 7,
              'The specified device has disconnected from us.')),
          ConnectFailure.unknown);
      expect(
          classify(FlutterBluePlusException(ErrorPlatform.apple, 'connect', 6,
              'The connection has timed out unexpectedly.')),
          ConnectFailure.outOfRange);
    });
  });

  group('BleManager.isPairingBrokenReason', () {
    bool broken(DisconnectReason? r) => BleManager.isPairingBrokenReason(r);

    test('iOS CBError 14 / 15', () {
      expect(
          broken(DisconnectReason(
              ErrorPlatform.apple, 14, 'Peer removed pairing information')),
          isTrue);
      expect(
          broken(DisconnectReason(
              ErrorPlatform.apple, 15, 'Encryption has timed out.')),
          isTrue);
    });

    test('a pairing description with an unexpected code', () {
      expect(
          broken(DisconnectReason(
              ErrorPlatform.apple, 0, 'Peer removed pairing information')),
          isTrue);
    });

    test('Android HCI 0x05 / 0x06 / 0x3D', () {
      for (final code in [0x05, 0x06, 0x3D]) {
        expect(broken(DisconnectReason(ErrorPlatform.android, code, null)),
            isTrue,
            reason: 'HCI $code');
      }
    });

    test('ordinary drops are not', () {
      expect(broken(null), isFalse);
      expect(
          broken(DisconnectReason(ErrorPlatform.apple, 7,
              'The specified device has disconnected from us.')),
          isFalse);
      expect(
          broken(DisconnectReason(ErrorPlatform.apple, 6,
              'The connection has timed out unexpectedly.')),
          isFalse);
      expect(
          broken(DisconnectReason(ErrorPlatform.android, 0x13,
              'REMOTE_USER_TERMINATED_CONNECTION')),
          isFalse);
      expect(
          broken(DisconnectReason(ErrorPlatform.apple,
              BleManager.fbpAppleUserCanceledCode, 'connection canceled')),
          isFalse);
    });
  });

  test('isOwnDisconnectReason', () {
    expect(
        BleManager.isOwnDisconnectReason(DisconnectReason(ErrorPlatform.apple,
            BleManager.fbpAppleUserCanceledCode, 'connection canceled')),
        isTrue);
    expect(
        BleManager.isOwnDisconnectReason(DisconnectReason(
            ErrorPlatform.apple, 14, 'Peer removed pairing information')),
        isFalse);
    expect(BleManager.isOwnDisconnectReason(null), isFalse);
  });

  group('LinkDropTracker', () {
    final t0 = DateTime(2026, 9, 27, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('two quick drops in a row = pairing broken (2nd attempt)', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      expect(t.linkDown(at(400)), LinkDropVerdict.quick);
      expect(t.quickDrops, 1);
      // Backoff re-arm, pending connect fires again seconds later.
      t.linkUp(at(6000));
      expect(t.linkDown(at(6400)), LinkDropVerdict.repeatedQuickDrops);
      expect(t.quickDrops, 0, reason: 'verdict resets the streak');
    });

    test('each drop is counted once, whichever path reports it first', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      t.linkUp(at(100)); // second report of the same link: ignored
      expect(t.linkDown(at(400)), LinkDropVerdict.quick);
      expect(t.linkDown(at(401)), isNull); // _onLinkLost / classify later
      expect(t.quickDrops, 1);
    });

    test('a drop without a recorded link-up is not counted', () {
      final t = LinkDropTracker();
      expect(t.linkDown(at(0)), isNull); // e.g. a failed direct connect
      expect(t.quickDrops, 0);
    });

    test('a link that held breaks the streak', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      expect(t.linkDown(at(300)), LinkDropVerdict.quick);
      t.linkUp(at(10000));
      expect(t.linkDown(at(60000)), LinkDropVerdict.normal);
      expect(t.quickDrops, 0);
      t.linkUp(at(70000));
      expect(t.linkDown(at(70300)), LinkDropVerdict.quick,
          reason: 'one quick drop after a normal one is not enough');
    });

    test('timing is measured from the first link-up report', () {
      final t = LinkDropTracker(quickWindow: const Duration(seconds: 4));
      t.linkUp(at(0));
      t.linkUp(at(3000));
      expect(t.linkDown(at(4500)), LinkDropVerdict.normal);
    });

    test('our own disconnects neither count nor break the streak', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      expect(t.linkDown(at(400)), LinkDropVerdict.quick);
      t.linkUp(at(3000));
      expect(t.linkDown(at(3100), intentional: true),
          LinkDropVerdict.intentional);
      expect(t.quickDrops, 1);
      t.linkUp(at(9000));
      expect(t.linkDown(at(9400)), LinkDropVerdict.repeatedQuickDrops);
    });

    test('a pairing reason decides at once, even on a long link', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      expect(t.linkDown(at(120000), pairingReason: true),
          LinkDropVerdict.pairingReason);
    });

    test('failed connect attempts (iOS didFailToConnect) count too', () {
      // A pending autoConnect that iOS fails with the stale keys: the app
      // never sees "connected", only "disconnected" with a reason.
      final t = LinkDropTracker();
      expect(t.linkFailed(), LinkDropVerdict.quick);
      expect(t.linkFailed(), LinkDropVerdict.repeatedQuickDrops);
    });

    test('a failed attempt with a pairing reason decides at once', () {
      final t = LinkDropTracker();
      expect(t.linkFailed(pairingReason: true), LinkDropVerdict.pairingReason);
      expect(t.quickDrops, 0);
    });

    test('a failed attempt and a quick drop make a streak', () {
      final t = LinkDropTracker();
      expect(t.linkFailed(), LinkDropVerdict.quick);
      t.linkUp(at(5000));
      expect(t.linkDown(at(5400)), LinkDropVerdict.repeatedQuickDrops);
    });

    test('reset clears the streak and the open link', () {
      final t = LinkDropTracker();
      t.linkUp(at(0));
      t.linkDown(at(300));
      t.linkUp(at(1000));
      t.reset();
      expect(t.isUp, isFalse);
      expect(t.quickDrops, 0);
      expect(t.linkDown(at(1200)), isNull);
    });
  });

  test('BleManager.isStatusTransitional', () {
    for (final s in ['', ' ', 'Unknown', 'NotConnected', 'Initializing',
        'Reconnecting']) {
      expect(BleManager.isStatusTransitional(s), isTrue, reason: "'$s'");
    }
    for (final s in ['HomeNet', 'Auth Failed', 'Connection Failed',
        'No credentials']) {
      expect(BleManager.isStatusTransitional(s), isFalse, reason: s);
    }
  });

  group('homeToyCardBusy', () {
    test('probing / connecting spin — but not during a pull', () {
      for (final p in [ToyPhase.probing, ToyPhase.connecting]) {
        expect(homeToyCardBusy(phase: p), isTrue);
        expect(homeToyCardBusy(phase: p, pullRefreshing: true), isFalse,
            reason: 'only the pull spinner shows');
      }
    });

    test('connected spins only while waiting for the first status', () {
      expect(
          homeToyCardBusy(phase: ToyPhase.connected, waitingForStatus: true),
          isTrue);
      expect(homeToyCardBusy(phase: ToyPhase.connected), isFalse);
      expect(
          homeToyCardBusy(
              phase: ToyPhase.connected,
              waitingForStatus: true,
              statusStalled: true),
          isFalse);
      expect(
          homeToyCardBusy(
              phase: ToyPhase.connected,
              waitingForStatus: true,
              advertSaysNoWifi: true),
          isFalse);
      expect(
          homeToyCardBusy(
              phase: ToyPhase.connected,
              waitingForStatus: true,
              pullRefreshing: true),
          isFalse);
    });

    test('settled states never spin', () {
      for (final p in [ToyPhase.noToy, ToyPhase.bluetoothOff,
          ToyPhase.needsPermission, ToyPhase.notNearby,
          ToyPhase.pairingBroken]) {
        expect(homeToyCardBusy(phase: p, waitingForStatus: true), isFalse,
            reason: p.name);
      }
    });
  });
}
