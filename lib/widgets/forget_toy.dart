import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/ble_manager.dart';
import 'remove_toy.dart';

/// Asks "Forget this Smarty?" and, on yes, forgets it on this phone
/// ([BleManager.forgetToy] unless [forget] is given — tests). Returns whether
/// it was forgotten. On iPhone ([isIOS], default: this phone) the dialog also
/// says to forget Smarty in Settings → Bluetooth, or setting it up again
/// later fails.
Future<bool> confirmAndForgetToy(
  BuildContext context, {
  Future<void> Function()? forget,
  bool? isIOS,
}) async {
  final bool ios = isIOS ?? Platform.isIOS;
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: const Text('Forget this Smarty?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Smarty will be disconnected from this phone. '
              'You can set it up again any time.',
            ),
            if (ios) ...[
              const SizedBox(height: 12),
              const Text(
                'To set it up again later, also forget it in '
                'Settings → Bluetooth.',
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Forget'),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      );
    },
  );
  if (confirmed != true) return false;
  await (forget ?? BleManager().forgetToy)();
  return true;
}

/// The toy card's small "⋯" button: opens a sheet with the rarely used
/// actions — "Forget this Smarty" ([onForget]: this phone only; should ask
/// first — see [confirmAndForgetToy]) and, when [onRemove] is given, "Remove
/// from my account" (should ask first — see [confirmAndRemoveToy]). Each says
/// in a line underneath what it does, so the two can't be mixed up.
class ToyMoreButton extends StatelessWidget {
  const ToyMoreButton({
    super.key,
    required this.onForget,
    this.onRemove,
    this.color,
  });

  final VoidCallback onForget;
  final VoidCallback? onRemove;
  final Color? color;

  /// Tooltip / screen-reader label of the button.
  static const String tooltip = 'More';

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.more_horiz, color: color),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: () => _openSheet(context),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final Color danger = Colors.red.shade400;
    final TextStyle titleStyle = TextStyle(
      color: danger,
      fontWeight: FontWeight.w600,
    );
    final _MoreAction? action = await showModalBottomSheet<_MoreAction>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.link_off, color: danger),
                  title: Text(forgetToyLabel, style: titleStyle),
                  subtitle: const Text(forgetToySubtitle),
                  onTap:
                      () => Navigator.of(sheetContext).pop(_MoreAction.forget),
                ),
                if (onRemove != null)
                  ListTile(
                    leading: Icon(Icons.person_remove_outlined, color: danger),
                    title: Text(removeToyLabel, style: titleStyle),
                    subtitle: const Text(removeToySubtitle),
                    onTap:
                        () =>
                            Navigator.of(sheetContext).pop(_MoreAction.remove),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
    switch (action) {
      case _MoreAction.forget:
        onForget();
      case _MoreAction.remove:
        onRemove?.call();
      case null:
        break;
    }
  }
}

enum _MoreAction { forget, remove }
