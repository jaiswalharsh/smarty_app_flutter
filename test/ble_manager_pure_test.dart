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
}
