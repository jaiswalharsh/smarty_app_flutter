import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  group('toyStatusLineFor', () {
    // (phase, wifi, registered, lastKnownWifiName, short, stalled, linking)
    //   → expected line
    final cases = <(ToyPhase, String, bool?, String?, bool, bool, bool, String)>[
      (ToyPhase.noToy, '', null, null, false, false, true,
          "Let's set up your Smarty"),
      (ToyPhase.noToy, '', null, null, true, false, true, 'Not set up yet'),
      (ToyPhase.bluetoothOff, '', null, null, true, false, true,
          'Bluetooth is off on this phone'),
      (ToyPhase.needsPermission, '', null, null, false, false, true,
          'Allow Bluetooth so the app can talk to Smarty'),
      (ToyPhase.probing, '', null, null, false, false, true,
          'Looking for Smarty…'),
      (ToyPhase.notNearby, '', null, null, true, false, true,
          'Asleep or out of reach'),
      (ToyPhase.connecting, '', null, null, false, false, true,
          'Connecting to Smarty…'),
      (ToyPhase.pairingBroken, '', null, null, true, false, true,
          'Needs reconnecting — see Home'),
      // Connected: waiting for the first status.
      (ToyPhase.connected, 'Unknown', null, null, false, false, true,
          'Checking on Smarty…'),
      (ToyPhase.connected, '', null, null, false, true, true,
          "Couldn't check on Smarty"),
      // Not linked yet — only with the account link switched on.
      (ToyPhase.connected, 'HomeNet', false, null, false, false, true,
          'Almost done — finish setup'),
      (ToyPhase.connected, 'HomeNet', false, null, false, false, false,
          'Ready to play'),
      // Unknown registration is not "unlinked".
      (ToyPhase.connected, 'HomeNet', null, null, false, false, true,
          'Ready to play'),
      (ToyPhase.connected, 'HomeNet', true, null, true, false, true,
          'Ready to play'),
      (ToyPhase.connected, 'Auth Failed', true, 'HomeNet', false, false, true,
          "Smarty can't join 'HomeNet' — was the password changed?"),
      (ToyPhase.connected, 'Auth Failed', true, null, false, false, true,
          "Smarty can't join your Wi-Fi — was the password changed?"),
      (ToyPhase.connected, 'Auth Failed', true, 'HomeNet', true, false, true,
          "Can't join Wi-Fi"),
      (ToyPhase.connected, 'Connection Failed', true, null, true, false, true,
          "Can't reach Wi-Fi"),
      (ToyPhase.connected, 'Reconnecting', true, null, false, false, true,
          'Smarty is joining Wi-Fi…'),
      (ToyPhase.connected, 'No credentials', true, null, false, false, true,
          "Smarty isn't on Wi-Fi yet"),
      (ToyPhase.connected, 'No credentials', true, null, true, false, true,
          'Not on Wi-Fi yet'),
    ];

    for (final c in cases) {
      final (phase, wifi, registered, lastWifi, short, stalled, linking,
          expected) = c;
      test('${phase.name} / "$wifi" / reg=$registered / short=$short '
          '/ stalled=$stalled / linking=$linking', () {
        expect(
          toyStatusLineFor(
            phase: phase,
            wifi: wifi,
            registered: registered,
            lastKnownWifiName: lastWifi,
            short: short,
            statusStalled: stalled,
            linkingEnabled: linking,
          ),
          expected,
        );
      });
    }

    test('never uses jargon', () {
      for (final phase in ToyPhase.values) {
        for (final short in [true, false]) {
          final line = toyStatusLineFor(
              phase: phase, wifi: 'HomeNet', registered: true, short: short);
          for (final word in ['BLE', 'scan', 'device']) {
            expect(line.contains(word), isFalse, reason: '$phase: $line');
          }
        }
      }
    });
  });
}
