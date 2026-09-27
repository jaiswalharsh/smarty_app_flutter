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

    test('"still looking" from 10 s, "stopped waiting" from 120 s', () {
      expect(scanHintFor(const Duration(seconds: 10), anyFound: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 30), anyFound: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 119), anyFound: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 120), anyFound: false),
          ScanHint.stoppedWaiting);
      expect(scanHintFor(const Duration(minutes: 5), anyFound: false),
          ScanHint.stoppedWaiting);
    });

    test('no hint once a toy has been found', () {
      expect(scanHintFor(const Duration(seconds: 45), anyFound: true),
          ScanHint.none);
      expect(
          scanHintFor(const Duration(seconds: 45),
              anyFound: true, seenNotPairing: true),
          ScanHint.none);
    });

    test('a Smarty that is around but not waiting to pair gets its own hint',
        () {
      expect(
          scanHintFor(const Duration(seconds: 5),
              anyFound: false, seenNotPairing: true),
          ScanHint.none);
      expect(
          scanHintFor(const Duration(seconds: 10),
              anyFound: false, seenNotPairing: true),
          ScanHint.notReadyToPair);
      // Still the more useful hint after the pairing window.
      expect(
          scanHintFor(const Duration(minutes: 3),
              anyFound: false, seenNotPairing: true),
          ScanHint.notReadyToPair);
    });
  });

  group('scanHintText', () {
    test('exact copy', () {
      expect(scanHintText(ScanHint.none), isNull);
      expect(scanHintText(ScanHint.stillLooking),
          'Still looking — did you hold both buttons?');
      expect(
          scanHintText(ScanHint.notReadyToPair),
          "We can see a Smarty, but it isn't ready to pair. Hold the + and – "
          'buttons on it for 3 seconds.');
      expect(scanHintText(ScanHint.stoppedWaiting),
          'Smarty stopped waiting. Hold the + and – buttons again.');
    });
  });

  group('timing', () {
    test('toy pairing windows and nudges', () {
      expect(pairingWindow, const Duration(seconds: 120));
      expect(firstBootPairingWindow, const Duration(minutes: 5));
      expect(scanStillLookingAfter, const Duration(seconds: 10));
      expect(scanStoppedWaitingAfter, pairingWindow);
      expect(autoSelectDelay, const Duration(milliseconds: 600));
    });

    test('instructions card copy', () {
      expect(setupFirstBootLine,
          "Just unboxed? Turn Smarty on — it's ready to pair for the first "
          '5 minutes.');
      expect(setupButtonHoldLine,
          'Otherwise, turn Smarty on and hold the + and – buttons together '
          'for 3 seconds. Smarty will wait 2 minutes for your phone.');
    });

    test('setup copy has no jargon', () {
      final lines = <String>[
        setupFirstBootLine,
        setupButtonHoldLine,
        for (final h in ScanHint.values)
          if (scanHintText(h) != null) scanHintText(h)!,
      ];
      for (final line in lines) {
        for (final word in [
          'advert', 'flag', 'byte', 'service data', 'BLE', 'scan', 'device',
        ]) {
          expect(line.toLowerCase().contains(word.toLowerCase()), isFalse,
              reason: '"$word" in: $line');
        }
      }
    });
  });

  group('isSetupCandidate', () {
    test('old firmware (no advert data) is listed', () {
      expect(isSetupCandidate(null), isTrue);
    });

    test('a toy waiting to pair is listed', () {
      expect(isSetupCandidate(const ToyAdvert(pairing: true, version: 1)),
          isTrue);
    });

    test('a toy that says it is NOT waiting to pair is hidden', () {
      expect(isSetupCandidate(const ToyAdvert(pairing: false, version: 1)),
          isFalse);
      expect(
          isSetupCandidate(const ToyAdvert(
              pairing: false, wifiUp: true, registered: true, version: 1)),
          isFalse);
      expect(isSetupCandidate(const ToyAdvert(pairing: false)), isFalse);
    });

    test('pairing not reported is listed', () {
      expect(isSetupCandidate(const ToyAdvert(version: 1)), isTrue);
    });
  });

  group('shouldAutoSelect', () {
    const pairingV1 = ToyAdvert(pairing: true, version: 1);
    const notPairingV1 = ToyAdvert(pairing: false, version: 1);
    const pairingV0 = ToyAdvert(pairing: true);

    // candidates → connect by ourselves?
    final cases = <(String, List<ToyAdvert?>, bool)>[
      ('nothing listed', [], false),
      ('one toy waiting to pair', [pairingV1], true),
      ('one old-firmware toy (no advert data)', [null], false),
      ('one toy with a version-0 advert', [pairingV0], false),
      ('one toy not waiting to pair', [notPairingV1], false),
      ('pairing not reported', [const ToyAdvert(version: 1)], false),
      ('two toys waiting to pair', [pairingV1, pairingV1], false),
      ('one waiting + one old-firmware toy', [pairingV1, null], false),
    ];
    for (final (label, candidates, expected) in cases) {
      test(label, () {
        expect(shouldAutoSelect(candidates), expected);
      });
    }
  });

  group('decideWifiStep', () {
    const early = Duration(seconds: 5);
    const justBefore = Duration(seconds: 19, milliseconds: 999);
    const atWait = Duration(seconds: 20);
    const late = Duration(seconds: 45);

    test('the wait is 20 s, re-reading every 3 s', () {
      expect(wifiCheckWait, const Duration(seconds: 20));
      expect(wifiRecheckEvery, const Duration(seconds: 3));
    });

    // (status, advertWifiUp, waited, retrying) → decision
    final rows = <(String?, bool?, Duration, bool, WifiDecision)>[
      // A real network name: on Wi-Fi, whatever else we know.
      ('HomeNet', null, Duration.zero, false, WifiDecision.connected),
      (' My Wi-Fi 5G ', false, early, false, WifiDecision.connected),
      ('HomeNet', false, late, true, WifiDecision.connected),
      // No status yet, the toy advertised "on Wi-Fi": trust it — finish.
      (null, true, Duration.zero, false, WifiDecision.connected),
      ('Unknown', true, early, false, WifiDecision.connected),
      ('NotConnected', true, late, false, WifiDecision.connected),
      ('', true, early, false, WifiDecision.connected),
      // No status yet, nothing (or "not on Wi-Fi") advertised: keep checking
      // for 20 s, then say so — never assume it needs setup.
      (null, null, Duration.zero, false, WifiDecision.checking),
      ('Unknown', false, justBefore, false, WifiDecision.checking),
      ('  ', null, early, true, WifiDecision.checking),
      (null, null, atWait, false, WifiDecision.couldNotCheck),
      ('Unknown', false, late, false, WifiDecision.couldNotCheck),
      ('NotConnected', null, late, true, WifiDecision.couldNotCheck),
      // Joining its saved Wi-Fi: checking; not up after 20 s = trouble.
      ('Initializing', null, early, false, WifiDecision.checking),
      ('Reconnecting', true, justBefore, false, WifiDecision.checking),
      ('Initializing', null, atWait, false, WifiDecision.unreachable),
      ('Reconnecting', false, late, true, WifiDecision.unreachable),
      // No Wi-Fi saved: straight to setup, even if the advert said otherwise.
      ('No credentials', null, Duration.zero, false, WifiDecision.needsSetup),
      ('No credentials', true, early, true, WifiDecision.needsSetup),
      ('No credentials', false, late, false, WifiDecision.needsSetup),
      // Wrong password on the saved Wi-Fi (status beats the advert).
      ('Auth Failed', null, Duration.zero, false, WifiDecision.authFailed),
      ('Auth Failed', true, early, false, WifiDecision.authFailed),
      ('Auth Failed', null, early, true, WifiDecision.checking),
      ('Auth Failed', null, atWait, true, WifiDecision.authFailed),
      // Saved Wi-Fi can't be reached.
      ('Connection Failed', null, Duration.zero, false,
          WifiDecision.unreachable),
      ('Connection Failed', true, late, false, WifiDecision.unreachable),
      ('Connection Failed', null, justBefore, true, WifiDecision.checking),
      ('Connection Failed', null, atWait, true, WifiDecision.unreachable),
      // Any other failure token counts as "can't reach".
      ('DHCP Failed', null, early, false, WifiDecision.unreachable),
      ('DHCP Failed', null, early, true, WifiDecision.checking),
    ];
    for (final (status, advert, waited, retrying, expected) in rows) {
      test('"$status" advert=$advert waited=${waited.inMilliseconds}ms '
          'retrying=$retrying → ${expected.name}', () {
        expect(
          decideWifiStep(
            status: status,
            advertWifiUp: advert,
            waited: waited,
            retrying: retrying,
          ),
          expected,
        );
      });
    }
  });

  group('Wi-Fi step copy', () {
    test('exact messages', () {
      expect(wifiCheckingLabel, "Checking Smarty's Wi-Fi…");
      expect(wifiDecisionMessage(WifiDecision.connected), isNull);
      expect(wifiDecisionMessage(WifiDecision.checking), isNull);
      expect(wifiDecisionMessage(WifiDecision.needsSetup),
          'Last step: connect Smarty to your home Wi-Fi. It only takes a minute.');
      expect(wifiDecisionMessage(WifiDecision.authFailed, ssid: 'HomeNet'),
          "Smarty can't connect to 'HomeNet' — the password may have changed.");
      expect(wifiDecisionMessage(WifiDecision.unreachable, ssid: 'HomeNet'),
          "Smarty can't reach 'HomeNet' — is the router on?");
      expect(wifiDecisionMessage(WifiDecision.couldNotCheck),
          "We couldn't check Smarty's Wi-Fi.");
    });

    test('no network name → "your Wi-Fi"', () {
      for (final ssid in [null, '', '  ']) {
        expect(wifiAuthFailedLine(ssid),
            "Smarty can't connect to your Wi-Fi — the password may have changed.");
        expect(wifiUnreachableLine(ssid),
            "Smarty can't reach your Wi-Fi — is the router on?");
      }
    });

    test('plain words only', () {
      final lines = <String>[
        wifiCheckingLabel,
        for (final d in WifiDecision.values)
          if (wifiDecisionMessage(d, ssid: 'HomeNet') != null)
            wifiDecisionMessage(d, ssid: 'HomeNet')!,
      ];
      for (final line in lines) {
        for (final word in [
          'SSID', 'BLE', 'scan', 'device', 'status', 'credentials', 'auth',
        ]) {
          expect(line.toLowerCase().contains(word.toLowerCase()), isFalse,
              reason: '"$word" in: $line');
        }
      }
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

    test('pairingBroken always ends with Try again, then the button hold as '
        'the fallback (a reset toy stops waiting after its pairing window)',
        () {
      const ending = "Then tap Try again. If Smarty doesn't show up, hold the "
          '+ and – buttons for 3 seconds.';
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

    test('iOS: numbered steps that match what Open Settings really does '
        "(it opens this app's page, not Settings → Bluetooth)", () {
      final steps = pairingBrokenStepList(isIOS: true);
      expect(steps, hasLength(4));
      expect(steps[0], 'Tap Open Settings.');
      expect(steps[1], contains('‹ at the top left'));
      expect(steps[1], contains('main Settings page, then tap Bluetooth'));
      expect(steps[2], 'Tap ⓘ next to Smarty and choose Forget This Device.');
      expect(steps[3], startsWith('Come back to this app.'));
      expect(pairingBrokenSteps(isIOS: true),
          '1. ${steps[0]}\n2. ${steps[1]}\n3. ${steps[2]}\n4. ${steps[3]}');
      // The old copy claimed the button opens Settings → Bluetooth.
      expect(pairingBrokenSteps(isIOS: true),
          isNot(contains('Open Settings → Bluetooth')));
      expect(
          connectFailureMessage(ConnectFailure.pairingBroken, isIOS: true),
          '$pairingBrokenHeading\n${pairingBrokenSteps(isIOS: true)}');
    });

    test('Android: one plain step, no numbering', () {
      expect(pairingBrokenStepList(isIOS: false),
          ['We cleared it on this phone. $pairingRepairFinalStep']);
      expect(pairingBrokenSteps(isIOS: false), isNot(startsWith('1.')));
    });

    test('iOS Bluetooth-off hint: Control Centre, or Settings the long way',
        () {
      expect(bluetoothOffHintIOS,
          startsWith('Swipe down from the top-right corner'));
      expect(bluetoothOffHintIOS, contains('Open Settings, then ‹'));
      expect(bluetoothOffHintIOS, endsWith('then tap Bluetooth.'));
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
