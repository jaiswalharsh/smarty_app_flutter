// Home's busy view (probing / connecting) with the real BleManager in its
// initial state — no Firebase, no BLE link needed as long as nothing is tapped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  testWidgets(
      'looking for Smarty: one inline spinner, and a visible way out if it drags on',
      (tester) async {
    expect(BleManager().phase.value, ToyPhase.probing);
    await tester.pumpWidget(const MaterialApp(home: HomeTab()));

    expect(find.text('Looking for Smarty…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Check again'), findsNothing);

    // Still looking after a while: offer "Check again" instead of spinning
    // with no way out.
    await tester.pump(const Duration(seconds: 13));
    expect(find.text('Check again'), findsOneWidget);
    expect(find.textContaining('taking longer than usual'), findsOneWidget);

    // Dispose so no timers are left pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
