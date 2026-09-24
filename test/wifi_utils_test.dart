import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/utils/wifi_utils.dart';

void main() {
  group('WifiUtils.processWifiScanData', () {
    test('empty input yields no networks', () {
      expect(WifiUtils.processWifiScanData(''), isEmpty);
    });

    test('parses framed firmware output and skips TOTAL/END markers', () {
      const data =
          'TOTAL:3\n'
          '0:HomeNet:-45,3\n'
          '1:CafeOpen:-70,0\n'
          '2:Neighbour:-80,4\n'
          'END';
      final networks = WifiUtils.processWifiScanData(data);
      expect(networks.map((n) => n.ssid), ['HomeNet', 'CafeOpen', 'Neighbour']);
      expect(networks[0].rssi, -45);
      expect(networks[0].auth, 3);
      expect(networks[0].isOpen, isFalse);
      expect(networks[1].isOpen, isTrue);
    });

    test('keeps colons inside the SSID', () {
      final networks = WifiUtils.processWifiScanData(
        'TOTAL:1\n0:My:Net:Work:-50,3\nEND',
      );
      expect(networks, hasLength(1));
      expect(networks.single.ssid, 'My:Net:Work');
      expect(networks.single.rssi, -50);
    });

    test(
      'dedups by SSID keeping the strongest signal, sorted strongest first',
      () {
        const data =
            '0:Weak:-85,3\n'
            '1:Dup:-80,3\n'
            '2:Dup:-40,3\n'
            '3:Mid:-60,0';
        final networks = WifiUtils.processWifiScanData(data);
        expect(networks.map((n) => n.ssid), ['Dup', 'Mid', 'Weak']);
        expect(networks.first.rssi, -40);
      },
    );

    test('a single framed line keeps its RSSI,AUTH tail', () {
      final networks = WifiUtils.processWifiScanData('0:Solo:-55,3');
      expect(networks.single.ssid, 'Solo');
      expect(networks.single.rssi, -55);
      expect(networks.single.auth, 3);
    });

    test('skips hidden (empty-SSID) access points', () {
      final networks = WifiUtils.processWifiScanData(
        '0::-40,3\n1:Visible:-50,3',
      );
      expect(networks.map((n) => n.ssid), ['Visible']);
    });

    test('legacy comma-separated SSID list is treated as unknown/secured', () {
      final networks = WifiUtils.processWifiScanData('Alpha,Beta');
      expect(networks.map((n) => n.ssid).toSet(), {'Alpha', 'Beta'});
      for (final n in networks) {
        expect(n.auth, -1);
        expect(n.isOpen, isFalse);
      }
    });
  });

  group('WifiUtils.getWifiStatusMessage', () {
    test('maps the exact firmware status tokens', () {
      expect(
        WifiUtils.getWifiStatusMessage('Initializing'),
        'WiFi is initializing...',
      );
      expect(
        WifiUtils.getWifiStatusMessage('Reconnecting'),
        'Reconnecting to WiFi...',
      );
      expect(
        WifiUtils.getWifiStatusMessage('No credentials'),
        'No WiFi network set up yet',
      );
      expect(
        WifiUtils.getWifiStatusMessage('NotConnected'),
        'WiFi is not connected',
      );
      expect(
        WifiUtils.getWifiStatusMessage('Auth Failed'),
        'WiFi password incorrect',
      );
      expect(
        WifiUtils.getWifiStatusMessage('Connection Failed'),
        'WiFi connection failed',
      );
      expect(WifiUtils.getWifiStatusMessage('Unknown'), 'WiFi status unknown');
    });

    test('trims surrounding whitespace before matching', () {
      expect(
        WifiUtils.getWifiStatusMessage('  Auth Failed \n'),
        'WiFi password incorrect',
      );
    });

    test('any other *Failed* status is a generic failure', () {
      expect(
        WifiUtils.getWifiStatusMessage('DHCP Failed'),
        'WiFi connection failed',
      );
    });

    test('anything else is treated as the connected SSID', () {
      expect(WifiUtils.getWifiStatusMessage('HomeNet'), 'Connected to HomeNet');
    });
  });
}
