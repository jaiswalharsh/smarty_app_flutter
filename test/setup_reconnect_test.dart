// A freshly installed app (or a new phone) meets the parent's own Smarty:
// Home offers "Reconnect your Smarty", and the setup page lists the toy as
// "Your Smarty" (matched by its Bluetooth name against the account's toys),
// connects to it by itself, and — when the toy was set up with another
// phone — says to hold its buttons rather than to forget anything in
// Settings. The setup page runs against the real BleManager with a fake
// connect; Bluetooth itself isn't available in tests, so scan results are
// handed to the page directly.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/providers/user_context_provider.dart';
import 'package:smarty_app/screens/devices/setup_steps.dart';
import 'package:smarty_app/screens/devices/smarty_connection_page.dart';
import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/services/known_toys_service.dart';
import 'package:smarty_app/utils/theme_provider.dart';
import 'package:smarty_app/widgets/forget_toy.dart';
import 'package:smarty_app/widgets/remove_toy.dart';

class FakeKnownToys implements KnownToys {
  FakeKnownToys(this.toys, {this.offer = true});

  final List<KnownToy> toys;
  bool offer;
  int asks = 0;
  int holdBacks = 0;

  /// removeFromAccount calls: (deviceId, keepHistory).
  final List<(String, bool)> removals = [];

  /// Makes removeFromAccount fail with this.
  RemoveToyException? removeError;

  /// Holds removeFromAccount until completed.
  Completer<void>? removeGate;

  @override
  Future<List<KnownToy>> knownToysForAccount() async {
    asks++;
    return List.of(toys);
  }

  @override
  Future<void> removeFromAccount(String deviceId,
      {required bool keepHistory}) async {
    removals.add((deviceId, keepHistory));
    final gate = removeGate;
    if (gate != null) await gate.future;
    final error = removeError;
    if (error != null) throw error;
    toys.removeWhere((t) => t.deviceId == deviceId);
  }

  @override
  bool get offerReconnect => offer;

  @override
  void holdBackReconnectOffer() {
    holdBacks++;
    offer = false;
  }
}

const KnownToy ownToy =
    KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E');
const KnownToy secondToy =
    KnownToy(deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-0E11');

/// A toy seen while looking: its name, BLE id, what it says about pairing
/// (null = old firmware, no advert data) and whether it says it is linked
/// to an account ([registered], flags bit2).
ScanResult toySeen(String name,
        {required String id, bool? pairing, bool registered = false}) =>
    ScanResult(
      device: BluetoothDevice.fromId(id),
      advertisementData: AdvertisementData(
        advName: name,
        txPowerLevel: null,
        appearance: null,
        connectable: true,
        manufacturerData: const {},
        serviceData: pairing == null
            ? const {}
            : {
                Guid('abcd'): [
                  (pairing ? 0x01 : 0x00) | (registered ? 0x04 : 0x00),
                  0x01,
                ],
              },
        serviceUuids: [Guid('abcd')],
      ),
      rssi: -50,
      timeStamp: DateTime(2026, 9, 30),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Setup page', () {
    late List<BluetoothDevice> connects;

    Future<SmartyConnectionPageState> pumpPage(
      WidgetTester tester, {
      KnownToy? reconnectTo,
      bool newToy = false,
      required FakeKnownToys known,
      ConnectException? failWith,
    }) async {
      connects = [];
      await tester.pumpWidget(MaterialApp(
        home: SmartyConnectionPage(
          reconnectTo: reconnectTo,
          newToy: newToy,
          knownToys: known,
          connectToy: (device) async {
            connects.add(device);
            throw failWith ??
                const ConnectException(ConnectFailure.pairingBroken);
          },
        ),
      ));
      await tester.pump();
      return tester.state<SmartyConnectionPageState>(
          find.byType(SmartyConnectionPage));
    }

    Future<void> see(WidgetTester tester, SmartyConnectionPageState page,
        List<ScanResult> results) async {
      page.debugApplyScanResults(results);
      await tester.pump();
    }

    // Dispose the page so its timers stop.
    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    testWidgets(
        'reconnect: "Your Smarty" with its code even when not waiting to '
        'pair, connected by itself; refused → hold the buttons, no Settings '
        'steps', (tester) async {
      final page = await pumpPage(tester,
          reconnectTo: ownToy, known: FakeKnownToys([ownToy]));

      expect(find.text('Reconnect Smarty'), findsOneWidget);
      expect(find.text('Looking for your Smarty…'), findsOneWidget);
      expect(find.text(reconnectFirstLine), findsOneWidget);
      expect(find.text('Look again'), findsNothing);

      await see(tester, page, [
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(find.text('Smarty found!'), findsOneWidget);
      expect(find.text('Your Smarty'), findsOneWidget);
      expect(find.text('B11E'), findsOneWidget);
      expect(find.text(otherToysHeading), findsNothing);
      expect(find.text(pairPromptNote(onlyYours: true)), findsOneWidget);
      expect(find.text('Look again'), findsNothing);
      expect(find.textContaining('ready to pair'), findsNothing);

      // The "Smarty found!" beat, then it connects by itself.
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:01']);

      expect(find.text(setUpWithAnotherPhoneMessage), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text(pairingBrokenHeading), findsNothing);
      expect(find.text('Open Settings'), findsNothing);
      expect(find.textContaining('Forget This Device'), findsNothing);
      await unmount(tester);
    });

    testWidgets('reconnect: the phone said its old pairing is stale → the '
        'old-pairing steps', (tester) async {
      final page = await pumpPage(tester,
          reconnectTo: ownToy,
          known: FakeKnownToys([ownToy]),
          failWith: const ConnectException(
              ConnectFailure.pairingBroken, null, true));
      await see(tester, page, [
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();

      expect(connects, hasLength(1));
      expect(find.text(pairingBrokenHeading), findsOneWidget);
      expect(find.text(setUpWithAnotherPhoneMessage), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        'reconnect: another toy around is not connected; ours is, once it '
        'shows up', (tester) async {
      final page = await pumpPage(tester,
          reconnectTo: ownToy, known: FakeKnownToys([ownToy]));
      await see(tester, page, [
        toySeen('Smarty-ABCD', id: 'AA:BB:CC:DD:EE:02', pairing: true),
      ]);
      await tester.pump(const Duration(seconds: 1));
      expect(connects, isEmpty);
      expect(find.text('Your Smarty'), findsNothing);

      await see(tester, page, [
        toySeen('Smarty-ABCD', id: 'AA:BB:CC:DD:EE:02', pairing: true),
        toySeen('smarty-b11e', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(find.text('Smarty toys nearby'), findsOneWidget);
      expect(find.text('Tap your Smarty.'), findsOneWidget);
      expect(find.text('Your Smarty'), findsOneWidget);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:01']);
      await unmount(tester);
    });

    testWidgets(
        'set up: the account\'s toy (from the account) is "Your Smarty" and, '
        'alone, connected by itself', (tester) async {
      final known = FakeKnownToys([ownToy]);
      final page = await pumpPage(tester, known: known);
      expect(known.asks, 1);
      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.text(setupFirstBootLine), findsOneWidget);
      expect(find.text(setupButtonHoldLine), findsOneWidget);

      await see(tester, page, [
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(find.text('Your Smarty'), findsOneWidget);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects, hasLength(1));
      await unmount(tester);
    });

    testWidgets(
        'set up: a toy that isn\'t waiting to pair and isn\'t ours goes under '
        '"Other Smarty toys nearby", greyed; never connected by itself; '
        'tapping tries, and a refusal says to hold the buttons',
        (tester) async {
      final page = await pumpPage(tester, known: FakeKnownToys([]));
      await see(tester, page, [
        toySeen('Smarty-1234', id: 'AA:BB:CC:DD:EE:03', pairing: false),
      ]);

      // Still looking for a toy to set up; the neighbour's is listed apart.
      expect(find.text('Looking for Smarty…'), findsOneWidget);
      expect(find.text(otherToysHeading), findsOneWidget);
      expect(find.text('Smarty 1234'), findsOneWidget);
      expect(find.text(otherToySubtitle), findsOneWidget);
      expect(find.text('Your Smarty'), findsNothing);
      expect(
        find.ancestor(
            of: find.text('Smarty 1234'), matching: find.byType(Opacity)),
        findsOneWidget,
      );
      expect(find.textContaining("isn't ready to pair"), findsNothing);
      expect(find.text('Look again'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(connects, isEmpty);

      await tester.tap(find.text('Smarty 1234'));
      await tester.pump();
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:03']);
      expect(find.text(setUpWithAnotherPhoneMessage), findsOneWidget);
      expect(find.text('Open Settings'), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        'reconnect: our LINKED toy refuses to pair → "couldn\'t confirm this '
        'is your Smarty", the reset under it — never the 3-second hold',
        (tester) async {
      final page = await pumpPage(tester,
          reconnectTo: ownToy, known: FakeKnownToys([ownToy]));
      await see(tester, page, [
        toySeen('Smarty-B11E',
            id: 'AA:BB:CC:DD:EE:01', pairing: false, registered: true),
      ]);
      expect(find.text('Your Smarty'), findsOneWidget);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:01']);

      expect(find.text(notConfirmedMessage), findsOneWidget);
      expect(find.text(resetAndSetUpAgainLine), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text(setUpWithAnotherPhoneMessage), findsNothing);
      expect(find.textContaining('3 seconds.'), findsOneWidget); // the reset
      expect(find.textContaining('for 3 seconds, then'), findsNothing);
      expect(find.text(pairingBrokenHeading), findsNothing);
      expect(find.textContaining('Add another phone'), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        'the toy turned down the account proof → the same "couldn\'t '
        'confirm" advice', (tester) async {
      final page = await pumpPage(tester,
          reconnectTo: ownToy,
          known: FakeKnownToys([ownToy]),
          failWith: const ConnectException(ConnectFailure.notYourAccount));
      await see(tester, page, [
        toySeen('Smarty-B11E',
            id: 'AA:BB:CC:DD:EE:01', pairing: false, registered: true),
      ]);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects, hasLength(1));
      expect(find.text(notConfirmedMessage), findsOneWidget);
      expect(find.text(resetAndSetUpAgainLine), findsOneWidget);
      expect(find.text(pairingBrokenHeading), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
        'set up: our linked toy is "Your Smarty" and connected by itself, '
        'whatever it says about pairing', (tester) async {
      final page = await pumpPage(tester, known: FakeKnownToys([ownToy]));
      await see(tester, page, [
        toySeen('Smarty-B11E',
            id: 'AA:BB:CC:DD:EE:01', pairing: true, registered: true),
      ]);
      expect(find.text('Your Smarty'), findsOneWidget);
      expect(find.text(otherFamilySubtitle), findsNothing);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects, hasLength(1));
      await unmount(tester);
    });

    testWidgets(
        "set up: a linked toy that isn't ours is another family's — greyed "
        'under "Other Smarty toys nearby", never connected; tapping explains',
        (tester) async {
      final known = FakeKnownToys([]);
      final page = await pumpPage(tester, known: known);
      await see(tester, page, [
        // Even while it waits to pair: it only takes its own family's phones.
        toySeen('Smarty-1234',
            id: 'AA:BB:CC:DD:EE:03', pairing: true, registered: true),
      ]);

      expect(find.text('Looking for Smarty…'), findsOneWidget);
      expect(find.text(otherToysHeading), findsOneWidget);
      expect(find.text('Smarty 1234'), findsOneWidget);
      expect(find.text(otherFamilySubtitle), findsOneWidget);
      expect(find.text(otherToySubtitle), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(
        find.ancestor(
            of: find.text('Smarty 1234'), matching: find.byType(Opacity)),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(connects, isEmpty);

      final int asksBefore = known.asks;
      await tester.tap(find.text('Smarty 1234'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(known.asks, asksBefore + 1); // asked again, just in case
      expect(connects, isEmpty);
      expect(find.text(otherFamilyHeading), findsOneWidget);
      expect(find.text(otherFamilyMessage('Smarty-1234')), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(otherFamilyHeading), findsNothing);
      expect(connects, isEmpty);
      expect(find.text('Smarty 1234'), findsOneWidget); // still looking
      await unmount(tester);
    });

    testWidgets(
        "another family's toy after all ours: the account's toys (read again "
        'on the tap) know it — connected as "Your Smarty"', (tester) async {
      final known = FakeKnownToys([]); // the first read came back empty
      final page = await pumpPage(tester, known: known);
      await see(tester, page, [
        toySeen('Smarty-B11E',
            id: 'AA:BB:CC:DD:EE:01', pairing: false, registered: true),
      ]);
      expect(find.text(otherFamilySubtitle), findsOneWidget);

      known.toys.add(ownToy); // now it answers
      await tester.tap(find.text('Smarty B11E'));
      await tester.pump();
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:01']);
      expect(find.text(otherFamilyHeading), findsNothing);
      await unmount(tester);
    });


    testWidgets(
        'instructions: reconnecting says a new phone just signs in with the '
        'same account — no button hold, nothing to do on another phone',
        (tester) async {
      await pumpPage(tester,
          reconnectTo: ownToy, known: FakeKnownToys([ownToy]));
      expect(find.text(reconnectFirstLine), findsOneWidget);
      expect(find.text(newPhoneLine), findsOneWidget);
      expect(find.textContaining('hold'), findsNothing);
      expect(find.textContaining('⋯'), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        'instructions: set up with a toy on the account adds the new-phone '
        'line; without one (or for a different Smarty) it doesn\'t',
        (tester) async {
      await pumpPage(tester, known: FakeKnownToys([ownToy]));
      await tester.pump();
      expect(find.text(setupFirstBootLine), findsOneWidget);
      expect(find.text(setupButtonHoldLine), findsOneWidget);
      expect(find.text(newPhoneLine), findsOneWidget);
      await unmount(tester);

      await pumpPage(tester, known: FakeKnownToys([]));
      await tester.pump();
      expect(find.text(setupButtonHoldLine), findsOneWidget);
      expect(find.text(newPhoneLine), findsNothing);
      await unmount(tester);

      await pumpPage(tester, newToy: true, known: FakeKnownToys([ownToy]));
      await tester.pump();
      expect(find.text(newPhoneLine), findsNothing);
      await unmount(tester);
    });

    testWidgets('a different Smarty: our own toy is listed but never '
        'connected by itself', (tester) async {
      final page =
          await pumpPage(tester, newToy: true, known: FakeKnownToys([ownToy]));
      await see(tester, page, [
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(find.text('Your Smarty'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(connects, isEmpty);
      await unmount(tester);
    });

    testWidgets(
        'set up: ours first as "Your Smarty", a new toy keeps its plain name; '
        'ours is the one connected by itself', (tester) async {
      final page = await pumpPage(tester, known: FakeKnownToys([ownToy]));
      await see(tester, page, [
        toySeen('Smarty-ABCD', id: 'AA:BB:CC:DD:EE:02', pairing: true),
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      // Ours first, then the new one.
      final double yours = tester.getTopLeft(find.text('Your Smarty')).dy;
      final double other = tester.getTopLeft(find.text('ABCD')).dy;
      expect(yours, lessThan(other));
      expect(find.text('Smarty'), findsOneWidget);
      expect(find.text('Smarty toys nearby'), findsOneWidget);
      expect(find.text(pairPromptNote(onlyYours: false)), findsOneWidget);
      await tester.pump(autoSelectDelay + const Duration(milliseconds: 50));
      await tester.pump();
      expect(connects.map((d) => d.remoteId.str), ['AA:BB:CC:DD:EE:01']);
      await unmount(tester);
    });
  });

  group('Setup page: reconnecting, and the toy is not there', () {
    late List<BluetoothDevice> connects;

    Future<SmartyConnectionPageState> pumpPage(
      WidgetTester tester, {
      KnownToy? reconnectTo = ownToy,
      required FakeKnownToys known,
    }) async {
      connects = [];
      await tester.pumpWidget(MaterialApp(
        home: SmartyConnectionPage(
          reconnectTo: reconnectTo,
          knownToys: known,
          connectToy: (device) async {
            connects.add(device);
            throw const ConnectException(ConnectFailure.pairingBroken);
          },
        ),
      ));
      await tester.pump();
      return tester.state<SmartyConnectionPageState>(
          find.byType(SmartyConnectionPage));
    }

    Future<void> see(WidgetTester tester, SmartyConnectionPageState page,
        List<ScanResult> results) async {
      page.debugApplyScanResults(results);
      await tester.pump();
    }

    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    Finder differentSmarty() => find.text('Set up a different Smarty');
    Finder noLongerHave() => find.text(noLongerHaveToyLabel);

    testWidgets(
        'after 30 s: "Set up a different Smarty" and "I don\'t have this '
        'Smarty any more" under the hint; gone once the toy shows up',
        (tester) async {
      final page =
          await pumpPage(tester, known: FakeKnownToys([ownToy]));
      await tester.pump(reconnectWayOutAfter - const Duration(seconds: 1));
      expect(differentSmarty(), findsNothing);
      expect(noLongerHave(), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(differentSmarty(), findsOneWidget);
      expect(noLongerHave(), findsOneWidget);
      // Below the look.
      expect(tester.getTopLeft(differentSmarty()).dy,
          greaterThan(tester.getTopLeft(find.text('Looking for your Smarty…')).dy));

      // Another toy around changes nothing…
      await see(tester, page, [
        toySeen('Smarty-ABCD', id: 'AA:BB:CC:DD:EE:02', pairing: true),
      ]);
      expect(noLongerHave(), findsOneWidget);
      // …ours showing up does.
      await see(tester, page, [
        toySeen('Smarty-ABCD', id: 'AA:BB:CC:DD:EE:02', pairing: true),
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(differentSmarty(), findsNothing);
      expect(noLongerHave(), findsNothing);
      await unmount(tester);
    });

    testWidgets('a plain setup never offers them', (tester) async {
      await pumpPage(tester,
          reconnectTo: null, known: FakeKnownToys([ownToy]));
      await tester.pump(reconnectWayOutAfter * 2);
      expect(noLongerHave(), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        '"Set up a different Smarty" carries on as a new-toy setup: our toy '
        'is listed but not connected by itself', (tester) async {
      final page =
          await pumpPage(tester, known: FakeKnownToys([ownToy]));
      await tester.pump(reconnectWayOutAfter);
      await tester.tap(differentSmarty());
      await tester.pump();

      expect(page.mode, SetupMode.newToy);
      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.text('Reconnect Smarty'), findsNothing);
      expect(find.text('Looking for Smarty…'), findsOneWidget);
      expect(find.text(setupFirstBootLine), findsOneWidget);
      expect(noLongerHave(), findsNothing);
      await tester.pump(reconnectWayOutAfter);
      expect(noLongerHave(), findsNothing);

      await see(tester, page, [
        toySeen('Smarty-B11E', id: 'AA:BB:CC:DD:EE:01', pairing: false),
      ]);
      expect(find.text('Your Smarty'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(connects, isEmpty);
      await unmount(tester);
    });

    testWidgets(
        '"I don\'t have this Smarty any more": asks, removes it, and goes '
        'back', (tester) async {
      final known = FakeKnownToys([ownToy]);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SmartyConnectionPage(
                    reconnectTo: ownToy,
                    knownToys: known,
                    connectToy: (_) async {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(reconnectWayOutAfter);

      await tester.tap(noLongerHave());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Remove Smarty-B11E from your account?'), findsOneWidget);

      // Cancel first: still here.
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(known.removals, isEmpty);
      expect(find.byType(SmartyConnectionPage), findsOneWidget);

      await tester.tap(noLongerHave());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(known.removals, [('1cc3abc9b11c', false)]);
      expect(find.byType(SmartyConnectionPage), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(find.text('Smarty-B11E was removed from your account.'),
          findsOneWidget);
    });
  });

  group('Home, no toy on this phone', () {
    Future<ValueNotifier<ToyPhase>> pumpHome(
      WidgetTester tester, {
      required FakeKnownToys known,
      ToyPhase phase = ToyPhase.noToy,
      Future<String?> Function()? savedToyCloudId,
    }) async {
      final toyPhase = ValueNotifier<ToyPhase>(phase);
      addTearDown(toyPhase.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(
              create: (_) => UserContextProvider(
                readFromToy: () async => null,
                writeToToy: (_) async => false,
                isToyConnected: () => false,
              ),
            ),
          ],
          child: MaterialApp(
            home: HomeTab(
              toyPhase: toyPhase,
              knownToys: known,
              savedToyCloudId: savedToyCloudId,
            ),
          ),
        ),
      );
      await tester.pump();
      return toyPhase;
    }

    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    testWidgets('the account has a toy: "Reconnect your Smarty"',
        (tester) async {
      final known = FakeKnownToys([ownToy]);
      await pumpHome(tester, known: known);

      expect(find.text('Reconnect your Smarty'), findsOneWidget);
      expect(find.text('You set up Smarty-B11E on this account before.'),
          findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Set up a different Smarty'), findsOneWidget);
      expect(find.text("Let's set up your Smarty"), findsNothing);
      expect(find.text('Set up Smarty'), findsNothing);
      expect(known.asks, 1);
      await unmount(tester);
    });

    testWidgets('the account has none: the plain setup', (tester) async {
      await pumpHome(tester, known: FakeKnownToys([]));
      expect(find.text("Let's set up your Smarty"), findsOneWidget);
      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.text('Reconnect your Smarty'), findsNothing);
      await unmount(tester);
    });

    testWidgets('held back after Forget: the plain setup, nothing asked',
        (tester) async {
      final known = FakeKnownToys([ownToy], offer: false);
      await pumpHome(tester, known: known);
      expect(find.text("Let's set up your Smarty"), findsOneWidget);
      expect(find.text('Reconnect your Smarty'), findsNothing);
      expect(known.asks, 0);
      await unmount(tester);
    });

    testWidgets('Connect opens the page in reconnect mode', (tester) async {
      await pumpHome(tester, known: FakeKnownToys([ownToy]));
      await tester.tap(find.text('Connect'));
      // (The page's spinner never settles: pump through the transition.)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Reconnect Smarty'), findsOneWidget);
      expect(find.text('Looking for your Smarty…'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('"Set up a different Smarty" opens the plain setup',
        (tester) async {
      await pumpHome(tester, known: FakeKnownToys([ownToy]));
      await tester.tap(find.text('Set up a different Smarty'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.text('Looking for Smarty…'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
        'asked each time Home arrives at "no toy"; Forget holds the offer '
        'back', (tester) async {
      final known = FakeKnownToys([ownToy]);
      final toyPhase =
          await pumpHome(tester, known: known, phase: ToyPhase.notNearby);
      expect(known.asks, 0); // a toy is saved on this phone

      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this Smarty'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(known.holdBacks, 1);

      toyPhase.value = ToyPhase.noToy;
      await tester.pump();
      await tester.pump();
      expect(find.text("Let's set up your Smarty"), findsOneWidget);
      expect(find.text('Reconnect your Smarty'), findsNothing);

      // Next launch / another account: offered again when Home gets here.
      known.offer = true;
      toyPhase.value = ToyPhase.probing;
      await tester.pump();
      toyPhase.value = ToyPhase.noToy;
      await tester.pump();
      await tester.pump();
      expect(find.text('Reconnect your Smarty'), findsOneWidget);
      expect(known.asks, 1);
      await unmount(tester);
    });

    testWidgets(
        'one toy: "I don\'t have this Smarty any more" asks first; Remove '
        'takes it off the account and Home offers a plain setup',
        (tester) async {
      final known = FakeKnownToys([ownToy]);
      await pumpHome(tester, known: known);
      expect(find.text(noLongerHaveToyLabel), findsOneWidget);

      await tester.tap(find.text(noLongerHaveToyLabel));
      await tester.pumpAndSettle();
      expect(find.text('Remove Smarty-B11E from your account?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(known.removals, isEmpty);
      expect(find.text('Reconnect your Smarty'), findsOneWidget);

      await tester.tap(find.text(noLongerHaveToyLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(known.removals, [('1cc3abc9b11c', false)]);
      expect(find.text('Smarty-B11E was removed from your account.'),
          findsOneWidget);
      expect(find.text("Let's set up your Smarty"), findsOneWidget);
      expect(find.text('Reconnect your Smarty'), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        'two toys: a row each — its name, Connect and "I don\'t have this '
        'Smarty any more"', (tester) async {
      final known = FakeKnownToys([ownToy, secondToy]);
      await pumpHome(tester, known: known);

      expect(find.text('Reconnect your Smarty'), findsOneWidget);
      expect(find.text('You set up 2 Smarty toys on this account before.'),
          findsOneWidget);
      expect(find.text('Smarty-B11E'), findsOneWidget);
      expect(find.text('Smarty-0E11'), findsOneWidget);
      expect(find.text('Connect'), findsNWidgets(2));
      expect(find.text(noLongerHaveToyLabel), findsNWidgets(2));
      expect(find.text('Set up a different Smarty'), findsOneWidget);
      // In the order the account lists them.
      expect(tester.getTopLeft(find.text('Smarty-B11E')).dy,
          lessThan(tester.getTopLeft(find.text('Smarty-0E11')).dy));

      // Connect on the second row reconnects that one.
      await tester.tap(find.text('Connect').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Reconnect Smarty'), findsOneWidget);
      expect(
          tester
              .widget<SmartyConnectionPage>(find.byType(SmartyConnectionPage))
              .reconnectTo,
          secondToy);
      await unmount(tester);
    });

    testWidgets(
        'two toys: removing one (keeping its chats) leaves the other, on its '
        'own', (tester) async {
      final known = FakeKnownToys([ownToy, secondToy]);
      await pumpHome(tester, known: known);

      await tester.tap(find.text(noLongerHaveToyLabel).first);
      await tester.pumpAndSettle();
      expect(find.text('Remove Smarty-B11E from your account?'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(known.removals, [('1cc3abc9b11c', true)]);
      expect(find.text('Smarty-B11E was removed from your account.'),
          findsOneWidget);
      expect(find.text('You set up Smarty-0E11 on this account before.'),
          findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text(noLongerHaveToyLabel), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a failed removal keeps the toy and says why', (tester) async {
      final known = FakeKnownToys([ownToy])
        ..removeError = const RemoveToyException(RemoveToyProblem.network);
      await pumpHome(tester, known: known);
      await tester.tap(find.text(noLongerHaveToyLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(
          find.text("We couldn't reach Smarty's server. Check your internet "
              'and try again.'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Reconnect your Smarty'), findsOneWidget);
      expect(find.textContaining('was removed'), findsNothing);
      await unmount(tester);
    });

    testWidgets(
        '⋯ on the saved toy: "Remove from my account" (as well as Forget) '
        'takes it off the account', (tester) async {
      final known = FakeKnownToys([ownToy]);
      await pumpHome(tester,
          known: known,
          phase: ToyPhase.notNearby,
          savedToyCloudId: () async => '1cc3abc9b11c');

      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
      expect(find.text('Forget this Smarty'), findsOneWidget);
      expect(find.text(forgetToySubtitle), findsOneWidget);
      expect(find.text('Remove from my account'), findsOneWidget);
      expect(find.text(removeToySubtitle), findsOneWidget);

      await tester.tap(find.text('Remove from my account'));
      await tester.pumpAndSettle();
      // (No toy name loaded in tests.)
      expect(find.text('Remove this Smarty from your account?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(known.removals, [('1cc3abc9b11c', false)]);
      expect(known.holdBacks, 0);
      expect(find.text('Smarty was removed from your account.'),
          findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
        '⋯ → Remove when the app can\'t tell which toy it is: says so, '
        'nothing removed', (tester) async {
      final known = FakeKnownToys([ownToy]);
      await pumpHome(tester,
          known: known,
          phase: ToyPhase.notNearby,
          savedToyCloudId: () async => null);
      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from my account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(known.removals, isEmpty);
      expect(
          find.text(
              const RemoveToyException(RemoveToyProblem.notOnAccount).message),
          findsOneWidget);
      await unmount(tester);
    });
  });
}
