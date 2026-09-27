import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/ble_manager.dart';

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
/// actions — for now only "Forget this Smarty" ([onForget], which should ask
/// first: see [confirmAndForgetToy]).
class ToyMoreButton extends StatelessWidget {
  const ToyMoreButton({super.key, required this.onForget, this.color});

  final VoidCallback onForget;
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
    final bool? forget = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.link_off, color: Colors.red.shade400),
                  title: Text(
                    'Forget this Smarty',
                    style: TextStyle(
                      color: Colors.red.shade400,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(true),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
    if (forget == true) onForget();
  }
}
