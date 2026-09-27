// Home's busy view (probing / connecting) with the real BleManager in its
// initial state — no Firebase, no BLE link needed as long as nothing is tapped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/widgets/smarty_card.dart';

void main() {
  testWidgets(
      'looking for Smarty: one inline spinner, and a visible way out if it drags on',
      (tester) async {
    Finder inCard(Finder f) =>
        find.descendant(of: find.byType(SmartyCard), matching: f);

    expect(BleManager().phase.value, ToyPhase.probing);
    await tester.pumpWidget(const MaterialApp(home: HomeTab()));

    expect(inCard(find.text('Looking for Smarty…')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(inCard(find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(find.text('Check again'), findsNothing);

    // Still looking after a while: offer "Check again" — inside the card —
    // instead of spinning with no way out.
    await tester.pump(const Duration(seconds: 13));
    expect(inCard(find.text('Check again')), findsOneWidget);
    expect(inCard(find.textContaining('taking longer than usual')),
        findsOneWidget);
    expect(find.byType(SmartyCard), findsOneWidget);

    // Dispose so no timers are left pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
