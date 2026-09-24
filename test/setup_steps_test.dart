import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/screens/devices/setup_steps.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  group('scanHintFor', () {
    test('no hint in the first 10 s', () {
      expect(scanHintFor(Duration.zero, anyFound: false), ScanHint.none);
      expect(scanHintFor(const Duration(seconds: 9), anyFound: false),
          ScanHint.none);
    });

    test('"still looking" from 10 s, "stopped waiting" from 30 s', () {
      expect(scanHintFor(const Duration(seconds: 10), anyFound: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 29), anyFound: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 30), anyFound: false),
          ScanHint.stoppedWaiting);
      expect(scanHintFor(const Duration(minutes: 5), anyFound: false),
          ScanHint.stoppedWaiting);
    });

    test('no hint once a toy has been found', () {
      expect(scanHintFor(const Duration(seconds: 45), anyFound: true),
          ScanHint.none);
    });
  });

  group('wifiStepFor', () {
    test('no status yet is unknown', () {
      for (final s in ['', '  ', 'Unknown', 'NotConnected']) {
        expect(wifiStepFor(s), WifiStep.unknown, reason: s);
      }
    });

    test('firmware transient states are joining', () {
      expect(wifiStepFor('Initializing'), WifiStep.joining);
      expect(wifiStepFor('Reconnecting'), WifiStep.joining);
    });

    test('states that need the parent', () {
      for (final s in ['No credentials', 'Auth Failed', 'Connection Failed']) {
        expect(wifiStepFor(s), WifiStep.needsSetup, reason: s);
      }
    });

    test('a real network name is connected', () {
      expect(wifiStepFor('HomeNet'), WifiStep.connected);
      expect(wifiStepFor(' My Wi-Fi 5G '), WifiStep.connected);
    });
  });

  group('connectFailureMessage', () {
    test('pairingBroken tells iOS parents how to forget the old pairing', () {
      final ios =
          connectFailureMessage(ConnectFailure.pairingBroken, isIOS: true);
      expect(ios, contains('Forget This Device'));
      final android =
          connectFailureMessage(ConnectFailure.pairingBroken, isIOS: false);
      expect(android, isNot(contains('Settings')));
    });

    test('pairingBroken always ends with the button hold (the toy stops '
        'waiting after 30 s)', () {
      const ending = 'Then hold the + and – buttons on Smarty together for 3 '
          'seconds and tap Try again.';
      expect(pairingRepairFinalStep, ending);
      for (final ios in [true, false]) {
        expect(
            connectFailureMessage(ConnectFailure.pairingBroken, isIOS: ios),
            endsWith(ending),
            reason: 'isIOS=$ios');
        // Home's pairing-broken view uses the same steps.
        expect(pairingBrokenSteps(isIOS: ios), endsWith(ending),
            reason: 'isIOS=$ios');
        expect(
            connectFailureMessage(ConnectFailure.pairingBroken, isIOS: ios),
            startsWith('Your phone remembers an old connection to Smarty.'));
      }
    });

    test('every kind has plain copy without jargon', () {
      for (final kind in ConnectFailure.values) {
        for (final ios in [true, false]) {
          final msg = connectFailureMessage(kind, isIOS: ios);
          expect(msg, isNotEmpty);
          for (final word in ['BLE', 'scan', 'device', 'Exception']) {
            expect(msg.contains(word), isFalse, reason: '$kind: $msg');
          }
        }
      }
    });
  });
}
