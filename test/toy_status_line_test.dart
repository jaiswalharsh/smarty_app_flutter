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
          "Smarty can't connect to 'HomeNet' — the password may have changed."),
      (ToyPhase.connected, 'Auth Failed', true, null, false, false, true,
          "Smarty can't connect to your Wi-Fi — the password may have changed."),
      (ToyPhase.connected, 'Auth Failed', true, 'HomeNet', true, false, true,
          "Can't join Wi-Fi"),
      (ToyPhase.connected, 'Connection Failed', true, null, true, false, true,
          "Can't reach Wi-Fi"),
      (ToyPhase.connected, 'Connection Failed', true, 'HomeNet', false, false,
          true, "Smarty can't reach 'HomeNet' — is the router on? It keeps trying."),
      (ToyPhase.connected, 'Connection Failed', true, null, false, false, true,
          "Smarty can't reach your Wi-Fi — is the router on? It keeps trying."),
      // Some other failure token: trouble, not "not set up yet".
      (ToyPhase.connected, 'DHCP Failed', true, null, false, false, true,
          'Smarty is having trouble with Wi-Fi'),
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

    test('not nearby but just seen: on and connecting', () {
      expect(
          toyStatusLineFor(
              phase: ToyPhase.notNearby,
              wifi: '',
              registered: null,
              seenRecently: true),
          'Smarty is on — connecting…');
      expect(
          toyStatusLineFor(
              phase: ToyPhase.notNearby,
              wifi: '',
              registered: null,
              seenRecently: true,
              short: true),
          'On — connecting…');
      expect(
          toyStatusLineFor(
              phase: ToyPhase.notNearby, wifi: '', registered: null),
          "Smarty is asleep or out of reach. Turn it on — it'll connect by "
          'itself.');
    });

    test('connected, no status yet, advert says not on Wi-Fi', () {
      String line({
        String wifi = 'Unknown',
        bool? advertWifiUp,
        bool stalled = false,
        bool short = false,
      }) =>
          toyStatusLineFor(
            phase: ToyPhase.connected,
            wifi: wifi,
            registered: null,
            advertWifiUp: advertWifiUp,
            statusStalled: stalled,
            short: short,
            linkingEnabled: true,
          );
      // Not "yet": the advert doesn't say whether Wi-Fi was ever set up.
      expect(line(advertWifiUp: false), "Smarty isn't on Wi-Fi right now");
      expect(line(advertWifiUp: false, short: true), 'Not on Wi-Fi');
      expect(line(advertWifiUp: true), 'Checking on Smarty…');
      expect(line(), 'Checking on Smarty…');
      // A stalled read still offers the retry.
      expect(line(advertWifiUp: false, stalled: true),
          "Couldn't check on Smarty");
      // The toy's own status always wins over the advert.
      expect(line(wifi: 'HomeNet', advertWifiUp: false), 'Ready to play');
    });

    test('"isn\'t on Wi-Fi yet" only for No credentials', () {
      const statuses = [
        'Unknown', '', 'NotConnected', 'Initializing', 'Reconnecting',
        'Auth Failed', 'Connection Failed', 'DHCP Failed', 'HomeNet',
        'No credentials',
      ];
      for (final wifi in statuses) {
        for (final advert in [null, true, false]) {
          for (final short in [true, false]) {
            final line = toyStatusLineFor(
              phase: ToyPhase.connected,
              wifi: wifi,
              registered: true,
              advertWifiUp: advert,
              short: short,
              linkingEnabled: true,
            );
            expect(line.contains('Wi-Fi yet'), wifi == 'No credentials',
                reason: '"$wifi" advert=$advert short=$short: $line');
          }
        }
      }
    });

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
