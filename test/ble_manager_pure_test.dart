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
}
