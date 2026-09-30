import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/services/ble_manager.dart';

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
}
