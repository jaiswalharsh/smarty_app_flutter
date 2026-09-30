import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/screens/devices/setup_steps.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  group('scanHintFor', () {
    test('no hint in the first 10 s', () {
      expect(scanHintFor(Duration.zero, anyListed: false), ScanHint.none);
      expect(scanHintFor(const Duration(seconds: 9), anyListed: false),
          ScanHint.none);
    });

    test('"still looking" from 10 s, "stopped waiting" from 120 s', () {
      expect(scanHintFor(const Duration(seconds: 10), anyListed: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 30), anyListed: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 119), anyListed: false),
          ScanHint.stillLooking);
      expect(scanHintFor(const Duration(seconds: 120), anyListed: false),
          ScanHint.stoppedWaiting);
      expect(scanHintFor(const Duration(minutes: 5), anyListed: false),
          ScanHint.stoppedWaiting);
    });

    test('no hint once a toy is listed', () {
      expect(scanHintFor(const Duration(seconds: 45), anyListed: true),
          ScanHint.none);
      expect(
          scanHintFor(const Duration(minutes: 5),
              anyListed: true, othersNearby: true),
          ScanHint.none);
    });

    test('toys under "Other Smarty toys nearby" say what to do themselves: '
        'no hint repeats it (and the old "isn\'t ready to pair" hint is gone)',
        () {
      for (final elapsed in [
        Duration.zero,
        const Duration(seconds: 10),
        const Duration(minutes: 3),
      ]) {
        expect(
            scanHintFor(elapsed, anyListed: false, othersNearby: true),
            ScanHint.none,
            reason: '$elapsed');
      }
    });

    test('looking for the account\'s own toy: one gentle nudge from 10 s, '
        'never "stopped waiting" (no buttons to hold)', () {
      expect(
          scanHintFor(const Duration(seconds: 9),
              anyListed: false, lookingForYours: true),
          ScanHint.none);
      for (final elapsed in [
        const Duration(seconds: 10),
        const Duration(minutes: 5),
      ]) {
        expect(scanHintFor(elapsed, anyListed: false, lookingForYours: true),
            ScanHint.stillLookingForYours,
            reason: '$elapsed');
      }
    });
  });

  group('lookingForYoursIn', () {
    test('reconnecting: always; setting up: when the account has a toy; a '
        'different Smarty: never', () {
      for (final has in [true, false]) {
        expect(lookingForYoursIn(SetupMode.reconnect, accountHasToys: has),
            isTrue);
        expect(lookingForYoursIn(SetupMode.setUp, accountHasToys: has), has);
        expect(
            lookingForYoursIn(SetupMode.newToy, accountHasToys: has), isFalse);
      }
    });
  });

  group('scanHintText', () {
    test('exact copy', () {
      expect(scanHintText(ScanHint.none), isNull);
      expect(scanHintText(ScanHint.stillLooking),
          'Still looking — did you hold both buttons?');
      expect(scanHintText(ScanHint.stoppedWaiting),
          'Smarty stopped waiting. Hold the + and – buttons again.');
      // The toy talks to one phone at a time.
      expect(scanHintText(ScanHint.stillLookingForYours),
          'Still looking — make sure Smarty is on and close to your phone. If '
          'Smarty is connected to another phone right now, close the Smarty '
          'app on that phone, then try again.');
      expect(otherPhoneConnectedLine,
          'If Smarty is connected to another phone right now, close the '
          'Smarty app on that phone, then try again.');
      expect(scanHintText(ScanHint.stillLookingForYours),
          isNot(contains('hold')));
    });

    test('no hint says "isn\'t ready to pair" any more', () {
      for (final h in ScanHint.values) {
        expect(scanHintText(h) ?? '', isNot(contains('ready to pair')),
            reason: h.name);
      }
    });
  });

  group('timing', () {
    test('toy pairing window and nudges', () {
      expect(pairingWindow, const Duration(seconds: 120));
      expect(pairingWindow, BleManager.toyPairingWindow);
      expect(scanStillLookingAfter, const Duration(seconds: 10));
      expect(scanStoppedWaitingAfter, pairingWindow);
      expect(autoSelectDelay, const Duration(milliseconds: 600));
    });

    test('instructions card copy', () {
      // A toy that has never been paired waits for as long as it is on.
      expect(setupFirstBootLine,
          "Just unboxed? Turn Smarty on — it's ready to pair.");
      expect(setupButtonHoldLine,
          'Otherwise hold the + and – buttons together for 3 seconds. '
          'Smarty will wait 2 minutes for your phone.');
      expect(reconnectFirstLine,
          'Turn Smarty on and keep it close to your phone.');
      // A second phone of the account just connects: nothing to do on the
      // first phone, no buttons to hold.
      expect(newPhoneLine,
          'Using a new phone? Just sign in with the same account — Smarty '
          'will let it pair.');
      expect(newPhoneLine, isNot(contains('hold')));
      expect(newPhoneLine, isNot(contains('⋯')));
    });

    test('the two-step factory reset', () {
      expect(factoryResetGesture,
          'hold + and – for 10 seconds, let go, then hold them again for 3 '
          'seconds');
      expect(resetAndSetUpAgainLine,
          'Reset Smarty: hold + and – for 10 seconds, let go, then hold them '
          'again for 3 seconds. Then set it up again.');
    });

    test('setup copy has no jargon', () {
      final lines = <String>[
        setupFirstBootLine,
        setupButtonHoldLine,
        reconnectFirstLine,
        newPhoneLine,
        otherPhoneConnectedLine,
        otherToySubtitle,
        otherToysHeading,
        otherFamilySubtitle,
        otherFamilyHeading,
        otherFamilyMessage(null),
        otherFamilyMessage('Smarty-B11E'),
        notConfirmedMessage,
        resetAndSetUpAgainLine,
        setUpWithAnotherPhoneMessage,
        maybeAnotherPhoneMessage,
        notYourToyMessage,
        pairPromptNote(onlyYours: true),
        pairPromptNote(onlyYours: false),
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

    test('a toy that says it is NOT waiting to pair is not a candidate', () {
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

    test('pairingBroken always ends with Try again — and no button hold: a '
        "toy linked to the account ignores it (the setup page's advice "
        'covers a refusal)', () {
      const ending = 'Then tap Try again.';
      expect(pairingRepairFinalStep, ending);
      for (final ios in [true, false]) {
        for (final step in pairingBrokenStepList(isIOS: ios)) {
          expect(step, isNot(contains('hold')), reason: step);
        }
      }
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

  group('toyListingFor', () {
    const pairing = ToyAdvert(pairing: true, registered: false, version: 1);
    const notPairing = ToyAdvert(pairing: false, registered: false, version: 1);
    const linked = ToyAdvert(pairing: false, registered: true, version: 1);
    const linkedPairing = ToyAdvert(pairing: true, registered: true, version: 1);

    test("the account's own toy is \"Your Smarty\" whatever its pairing bit",
        () {
      for (final advert in [pairing, notPairing, null,
          const ToyAdvert(version: 1), linked, linkedPairing]) {
        expect(toyListingFor(advert, yours: true), ToyListing.yours,
            reason: '$advert');
      }
    });

    test("linked to an account that isn't ours → another family's, whatever "
        'it says about pairing (never connected)', () {
      expect(toyListingFor(linked, yours: false), ToyListing.otherFamily);
      expect(toyListingFor(linkedPairing, yours: false),
          ToyListing.otherFamily);
      // From real advert bytes: flags bit2 = linked.
      expect(
          toyListingFor(
              ToyAdvert.fromServiceData({BleManager.smartyServiceGuid: [0x04, 0x01]}),
              yours: false),
          ToyListing.otherFamily);
      expect(
          toyListingFor(
              ToyAdvert.fromServiceData({BleManager.smartyServiceGuid: [0x05, 0x01]}),
              yours: false),
          ToyListing.otherFamily);
    });

    test('firmware that says nothing about being linked: as before', () {
      expect(toyListingFor(null, yours: false), ToyListing.candidate);
      expect(toyListingFor(const ToyAdvert(pairing: false), yours: false),
          ToyListing.other);
      expect(toyListingFor(const ToyAdvert(pairing: true), yours: false),
          ToyListing.candidate);
    });

    test('other toys: waiting to pair (or not saying) → a candidate', () {
      expect(toyListingFor(pairing, yours: false), ToyListing.candidate);
      expect(toyListingFor(null, yours: false), ToyListing.candidate);
      expect(toyListingFor(const ToyAdvert(version: 1), yours: false),
          ToyListing.candidate);
    });

    test('not waiting to pair and not ours → "Other Smarty toys nearby"', () {
      expect(toyListingFor(notPairing, yours: false), ToyListing.other);
      expect(toyListingFor(const ToyAdvert(pairing: false), yours: false),
          ToyListing.other);
    });

    test('copy', () {
      expect(otherToysHeading, 'Other Smarty toys nearby');
      expect(otherToySubtitle,
          'Set up with another phone — hold + and – on it to pair');
      expect(otherFamilySubtitle, 'Set up by another family');
      expect(otherFamilyHeading, 'This Smarty belongs to another family');
      expect(
          otherFamilyMessage('smarty-b11e'),
          "It's linked to their account, so it can't be set up here. First "
          'they need to remove it from their account (Smarty app → Home → ⋯ '
          "→ Remove from my account) — resetting the toy alone isn't enough. "
          "If you can't reach them, contact office@hey-smarty.com with the "
          'code on the toy '
          '(Smarty-B11E).');
      expect(otherFamilyMessage(null), endsWith('(Smarty-XXXX).'));
      // Nothing there tells a stranger how to get in.
      expect(otherFamilyMessage(null), isNot(contains('hold')));
    });
  });

  group('othersShowHowToPair', () {
    test("a toy that isn't linked says to hold its buttons: no hint needed",
        () {
      expect(othersShowHowToPair([ToyListing.other]), isTrue);
      expect(othersShowHowToPair([ToyListing.otherFamily, ToyListing.other]),
          isTrue);
    });

    test("only another family's toys: they say nothing about the parent's "
        'own — the hint still comes', () {
      expect(othersShowHowToPair([ToyListing.otherFamily]), isFalse);
      expect(othersShowHowToPair(const []), isFalse);
      expect(
          scanHintFor(scanStillLookingAfter,
              anyListed: false,
              othersNearby: othersShowHowToPair([ToyListing.otherFamily])),
          ScanHint.stillLooking);
    });
  });

  group('autoSelectIndex', () {
    const pairing = ToyAdvert(pairing: true, version: 1);
    const notPairing = ToyAdvert(pairing: false, version: 1);
    ListedToy mine(ToyAdvert? a, {bool target = false}) =>
        (advert: a, yours: true, target: target);
    ListedToy theirs(ToyAdvert? a) => (advert: a, yours: false, target: false);

    // (label, mode, listed) → index connected by itself (null = wait for a tap)
    final cases = <(String, SetupMode, List<ListedToy>, int?)>[
      // Reconnect: the toy being reconnected, whatever else is around.
      ('reconnect: the toy, not waiting to pair', SetupMode.reconnect,
          [mine(notPairing, target: true)], 0),
      ('reconnect: the toy after a new toy', SetupMode.reconnect,
          [theirs(pairing), mine(null, target: true)], 1),
      ('reconnect: only a different toy of ours', SetupMode.reconnect,
          [mine(notPairing)], null),
      ('reconnect: only a new toy waiting to pair', SetupMode.reconnect,
          [theirs(pairing)], null),
      ('reconnect: two toys with its name', SetupMode.reconnect,
          [mine(pairing, target: true), mine(pairing, target: true)], null),
      ('reconnect: nothing', SetupMode.reconnect, [], null),
      // Set up: a lone toy of ours, or a lone toy waiting to pair.
      ('set up: lone toy of ours not waiting to pair', SetupMode.setUp,
          [mine(notPairing)], 0),
      ('set up: lone toy of ours, old firmware', SetupMode.setUp,
          [mine(null)], 0),
      ('set up: lone new toy waiting to pair', SetupMode.setUp,
          [theirs(pairing)], 0),
      ('set up: lone new toy, old firmware', SetupMode.setUp,
          [theirs(null)], null),
      ('set up: a new toy + ours → ours', SetupMode.setUp,
          [theirs(pairing), mine(notPairing)], 1),
      ('set up: two of ours', SetupMode.setUp,
          [mine(notPairing), mine(pairing)], null),
      ('set up: two new toys', SetupMode.setUp,
          [theirs(pairing), theirs(pairing)], null),
      // A different Smarty: ours never; a lone new toy waiting to pair yes.
      ('new toy: only ours', SetupMode.newToy, [mine(pairing)], null),
      ('new toy: ours + a new toy waiting to pair', SetupMode.newToy,
          [mine(notPairing), theirs(pairing)], 1),
      ('new toy: ours + a new old-firmware toy', SetupMode.newToy,
          [mine(notPairing), theirs(null)], null),
      ('new toy: two new toys', SetupMode.newToy,
          [theirs(pairing), theirs(pairing)], null),
    ];
    for (final (label, mode, listed, expected) in cases) {
      test(label, () {
        expect(autoSelectIndex(listed, mode: mode), expected);
      });
    }
  });

  group('lookSectionView — header / hint / button per state', () {
    // (label, view) → [header, subtitle?, hint?, 'Look again'?], icon
    final rows = <(String, LookSectionView, List<String>, LookIcon)>[
      ('connecting',
          lookSectionView(connecting: true, listed: 1, scanStopped: false),
          ['Connecting to Smarty…'], LookIcon.spinner),
      ('connecting (reconnect)',
          lookSectionView(
              connecting: true, listed: 1, scanStopped: false,
              reconnect: true),
          ['Connecting to your Smarty…'], LookIcon.spinner),
      ('looking, nothing yet',
          lookSectionView(connecting: false, listed: 0, scanStopped: false),
          ['Looking for Smarty…'], LookIcon.spinner),
      ('looking, 10 s',
          lookSectionView(
              connecting: false, listed: 0, scanStopped: false,
              hint: ScanHint.stillLooking),
          ['Looking for Smarty…', 'Still looking — did you hold both buttons?'],
          LookIcon.spinner),
      ('looking, 120 s',
          lookSectionView(
              connecting: false, listed: 0, scanStopped: false,
              hint: ScanHint.stoppedWaiting),
          [
            'Looking for Smarty…',
            'Smarty stopped waiting. Hold the + and – buttons again.',
          ],
          LookIcon.spinner),
      ('reconnecting, 10 s',
          lookSectionView(
              connecting: false, listed: 0, scanStopped: false,
              hint: ScanHint.stillLookingForYours, reconnect: true),
          [
            'Looking for your Smarty…',
            'Still looking — make sure Smarty is on and close to your phone. '
                'If Smarty is connected to another phone right now, close the '
                'Smarty app on that phone, then try again.',
          ],
          LookIcon.spinner),
      ('one toy listed',
          lookSectionView(connecting: false, listed: 1, scanStopped: false),
          ['Smarty found!'], LookIcon.found),
      ('several toys listed',
          lookSectionView(connecting: false, listed: 2, scanStopped: false),
          ['Smarty toys nearby', 'Tap the one you are setting up.'],
          LookIcon.none),
      ('several toys listed (reconnect)',
          lookSectionView(
              connecting: false, listed: 3, scanStopped: false,
              reconnect: true),
          ['Smarty toys nearby', 'Tap your Smarty.'], LookIcon.none),
      ('the look stopped, nothing listed',
          lookSectionView(
              connecting: false, listed: 0, scanStopped: true,
              hint: ScanHint.stillLooking),
          [
            'Stopped looking for Smarty',
            'Something got in the way on this phone.',
            'Look again',
          ],
          LookIcon.none),
      ('the look stopped, one listed',
          lookSectionView(connecting: false, listed: 1, scanStopped: true),
          ['Smarty found!', 'Stopped looking for more toys.', 'Look again'],
          LookIcon.found),
      ('the look stopped, several listed',
          lookSectionView(connecting: false, listed: 2, scanStopped: true),
          [
            'Smarty toys nearby',
            'Tap the one you are setting up.',
            'Stopped looking for more toys.',
            'Look again',
          ],
          LookIcon.none),
    ];
    for (final (label, view, texts, icon) in rows) {
      test(label, () {
        expect(view.texts, texts);
        expect(view.icon, icon);
      });
    }

    test('while the look is running there is never a "Look again" button '
        '(the hints are text only)', () {
      for (final listed in [0, 1, 2, 5]) {
        for (final hint in ScanHint.values) {
          for (final reconnect in [false, true]) {
            for (final connecting in [false, true]) {
              final view = lookSectionView(
                connecting: connecting,
                listed: listed,
                scanStopped: false,
                hint: hint,
                reconnect: reconnect,
              );
              expect(view.showLookAgain, isFalse, reason: '$view');
              expect(view.texts, isNot(contains('Look again')));
            }
          }
        }
      }
    });

    test('"Looking for Smarty…" never shows together with "Look again", and '
        'no two lines say the same thing', () {
      for (final listed in [0, 1, 2]) {
        for (final stopped in [false, true]) {
          for (final hint in ScanHint.values) {
            for (final reconnect in [false, true]) {
              final view = lookSectionView(
                connecting: false,
                listed: listed,
                scanStopped: stopped,
                hint: hint,
                reconnect: reconnect,
              );
              if (view.header.startsWith('Looking for')) {
                expect(view.showLookAgain, isFalse, reason: '$view');
                expect(view.icon, LookIcon.spinner, reason: '$view');
              }
              if (view.showLookAgain) {
                expect(view.icon, isNot(LookIcon.spinner), reason: '$view');
              }
              expect(view.texts.toSet(), hasLength(view.texts.length),
                  reason: '$view');
              final lower = [for (final t in view.texts) t.toLowerCase()];
              for (var i = 0; i < lower.length; i++) {
                for (var j = 0; j < lower.length; j++) {
                  if (i != j) {
                    expect(lower[i].contains(lower[j]), isFalse,
                        reason: '$view');
                  }
                }
              }
            }
          }
        }
      }
    });

    test('once something is listed, no hint while the look runs', () {
      for (final hint in ScanHint.values) {
        final view = lookSectionView(
            connecting: false, listed: 1, scanStopped: false, hint: hint);
        expect(view.hint, isNull, reason: hint.name);
      }
    });
  });

  group('pairPromptNote', () {
    test('only toys of ours → "if"; otherwise "will ask"', () {
      expect(pairPromptNote(onlyYours: true),
          'If your phone asks to pair with Smarty, tap Pair.');
      expect(pairPromptNote(onlyYours: false),
          'Your phone will ask to pair with Smarty — tap Pair.');
    });
  });

  group('connectAdviceFor', () {
    // (label, kind, staleBond, yours, advertPairing) → advice
    final rows = <(String, ConnectFailure, bool, bool, bool?, ConnectAdvice)>[
      // Our toy on a new phone: nothing old on this phone — hold the buttons.
      ('ours, refused, no stale pairing', ConnectFailure.pairingBroken, false,
          true, false, ConnectAdvice.holdButtons),
      ('ours, refused, pairing not reported', ConnectFailure.pairingBroken,
          false, true, null, ConnectAdvice.holdButtons),
      // The phone said the toy dropped its pairing: forget it first.
      ('ours, the phone reported a stale pairing',
          ConnectFailure.pairingBroken, true, true, false,
          ConnectAdvice.forgetOldPairing),
      // The toy was waiting to pair, so the old pairing on this phone is it.
      ('ours, refused while waiting to pair', ConnectFailure.pairingBroken,
          false, true, true, ConnectAdvice.forgetOldPairing),
      // "Other Smarty toys nearby": set up with another phone.
      ('other toy, refused', ConnectFailure.pairingBroken, false, false, false,
          ConnectAdvice.holdButtons),
      ('other toy, stale pairing reported', ConnectFailure.pairingBroken, true,
          false, false, ConnectAdvice.forgetOldPairing),
      // A new toy (waiting to pair / old firmware): as before.
      ('new toy, refused', ConnectFailure.pairingBroken, false, false, true,
          ConnectAdvice.forgetOldPairing),
      ('old-firmware toy, refused', ConnectFailure.pairingBroken, false, false,
          null, ConnectAdvice.forgetOldPairing),
      // The link just didn't come up with a toy that isn't waiting to pair.
      ('not waiting to pair, unknown failure', ConnectFailure.unknown, false,
          true, false, ConnectAdvice.maybeHoldButtons),
      ('waiting to pair, unknown failure', ConnectFailure.unknown, false,
          true, true, ConnectAdvice.plain),
      ('ours, out of range', ConnectFailure.outOfRange, false, true, false,
          ConnectAdvice.plain),
      ('ours, pairing cancelled', ConnectFailure.cancelledByUser, false, true,
          false, ConnectAdvice.plain),
    ];
    // (The toy doesn't say whether it is linked here — registered null —
    // or says it isn't: the button hold still works for it.)
    for (final (label, kind, stale, yours, advertPairing, expected) in rows) {
      for (final registered in [null, false]) {
        test('$label (linked: $registered)', () {
          expect(
            connectAdviceFor(kind,
                staleBond: stale,
                yours: yours,
                advertPairing: advertPairing,
                registered: registered),
            expected,
          );
        });
      }
    }

    // A toy linked to an account: a phone of the account proves it and
    // pairs; a refusal means the proof wasn't there (or was wrong). Its
    // buttons can't help.
    // (label, kind, staleBond, yours, advertPairing) → advice
    final linkedRows = <(String, ConnectFailure, bool, bool, bool?,
        ConnectAdvice)>[
      ('linked, ours, refused, not waiting to pair',
          ConnectFailure.pairingBroken, false, true, false,
          ConnectAdvice.notConfirmed),
      ('linked, ours, refused, pairing not reported',
          ConnectFailure.pairingBroken, false, true, null,
          ConnectAdvice.notConfirmed),
      ('linked, not known as ours, refused', ConnectFailure.pairingBroken,
          false, false, false, ConnectAdvice.notConfirmed),
      // The phone said its own old pairing is what got in the way.
      ('linked, the phone reported a stale pairing',
          ConnectFailure.pairingBroken, true, true, false,
          ConnectAdvice.forgetOldPairing),
      ('linked, refused while waiting to pair', ConnectFailure.pairingBroken,
          false, true, true, ConnectAdvice.forgetOldPairing),
      // The link just didn't come up: plain, never the button hold.
      ('linked, not waiting to pair, unknown failure', ConnectFailure.unknown,
          false, true, false, ConnectAdvice.plain),
      ('linked, waiting to pair, unknown failure', ConnectFailure.unknown,
          false, true, true, ConnectAdvice.plain),
      ('linked, out of range', ConnectFailure.outOfRange, false, true, false,
          ConnectAdvice.plain),
    ];
    for (final (label, kind, stale, yours, advertPairing, expected)
        in linkedRows) {
      test(label, () {
        expect(
          connectAdviceFor(kind,
              staleBond: stale,
              yours: yours,
              advertPairing: advertPairing,
              registered: true),
          expected,
        );
      });
    }

    test('the toy turned down the account proof → "couldn\'t confirm", '
        'whatever else is known', () {
      for (final registered in [true, false, null]) {
        for (final stale in [true, false]) {
          expect(
            connectAdviceFor(ConnectFailure.notYourAccount,
                staleBond: stale, yours: true, registered: registered),
            ConnectAdvice.notConfirmed,
            reason: 'registered=$registered stale=$stale',
          );
        }
      }
    });

    test('the 3-second hold only for a toy that isn\'t linked', () {
      for (final kind in ConnectFailure.values) {
        for (final pairing in [true, false, null]) {
          for (final yours in [true, false]) {
            final ConnectAdvice a = connectAdviceFor(kind,
                yours: yours, advertPairing: pairing, registered: true);
            expect(
                a == ConnectAdvice.holdButtons ||
                    a == ConnectAdvice.maybeHoldButtons,
                isFalse,
                reason: '$kind pairing=$pairing yours=$yours');
          }
        }
      }
    });

    test('copy: couldn\'t confirm — check the account; the reset as the way '
        'out; never the 3-second hold', () {
      expect(notConfirmedMessage,
          "Couldn't confirm this is your Smarty. Check you're signed in with "
          'the account it was set up with, then tap Try again.');
      expect(connectFailureMessage(ConnectFailure.notYourAccount, isIOS: true),
          notConfirmedMessage);
      expect(connectFailureMessage(ConnectFailure.notYourAccount, isIOS: false),
          notConfirmedMessage);
      expect(notConfirmedMessage, isNot(contains('3 seconds')));
      expect(notConfirmedMessage, isNot(contains('Settings')));
      expect(resetAndSetUpAgainLine, contains(factoryResetGesture));
    });

    test('copy: hold the buttons — no Settings steps', () {
      expect(setUpWithAnotherPhoneMessage,
          'This Smarty was set up with another phone. Hold the + and – '
          'buttons on it for 3 seconds, then tap Try again.');
      expect(setUpWithAnotherPhoneMessage, isNot(contains('Settings')));
      expect(maybeAnotherPhoneMessage,
          startsWith("We couldn't finish connecting."));
      expect(maybeAnotherPhoneMessage, isNot(contains('Settings')));
      expect(notYourToyMessage, contains('Try again'));
    });
  });
}
