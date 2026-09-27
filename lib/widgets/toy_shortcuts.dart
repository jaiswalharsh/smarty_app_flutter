import 'package:flutter/material.dart';

import '../services/ble_manager.dart';

/// Whether Home shows the Smarty shortcuts ([ToyShortcuts]) in [phase]
/// (pure, for tests): whenever a toy is saved — not in [ToyPhase.noToy],
/// where Home offers "Set up Smarty" instead.
bool homeShowsToyShortcuts(ToyPhase phase) => phase != ToyPhase.noToy;

/// Subtitle of the Wi-Fi shortcut while Smarty is connected, from the raw
/// `wifi` status value it reported: the network's name once it's on Wi-Fi,
/// otherwise a few plain words. Pure (tests).
String wifiShortcutDetail(String wifi) {
  final String status = wifi.trim();
  if (status.isEmpty || status == 'Unknown' || status == 'NotConnected') {
    return 'Checking…';
  }
  if (BleManager.isWifiConnectedStatus(status)) return status;
  if (status == 'Initializing' || status == 'Reconnecting') return 'Joining…';
  return 'Not connected';
}

/// Subtitle of the Wi-Fi shortcut while Smarty isn't connected.
const String wifiShortcutAwayDetail = 'Available when Smarty is nearby';

/// Home's compact list under the toy card: Wi-Fi (only while Smarty is
/// connected — its Wi-Fi is set over Bluetooth) and About your child (any
/// time; edits made while Smarty is away are sent when it's back).
class ToyShortcuts extends StatelessWidget {
  const ToyShortcuts({
    super.key,
    required this.connected,
    required this.wifi,
    required this.onWifi,
    required this.onAboutChild,
  });

  /// Smarty is connected ([ToyPhase.connected]).
  final bool connected;

  /// The raw `wifi` status Smarty last reported (see [wifiShortcutDetail]).
  final String wifi;
  final VoidCallback onWifi;
  final VoidCallback onAboutChild;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? const Color(0xFF2C2C44) : Colors.blue.shade50,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ToyShortcutRow(
              icon: Icons.wifi,
              label: 'Wi-Fi',
              detail:
                  connected ? wifiShortcutDetail(wifi) : wifiShortcutAwayDetail,
              onTap: connected ? onWifi : null,
            ),
            ToyShortcutRow(
              icon: Icons.chat_bubble,
              label: 'About your child',
              detail: 'What Smarty should know about your child',
              onTap: onAboutChild,
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable line in [ToyShortcuts]: icon, label, optional detail, and a
/// chevron. Greyed out and not tappable when [onTap] is null.
class ToyShortcutRow extends StatelessWidget {
  const ToyShortcutRow({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool enabled = onTap != null;
    final Color base = dark ? Colors.white : Colors.black87;
    final Color fg = enabled ? base : base.withValues(alpha: 0.4);
    final Color muted = (dark ? Colors.white70 : Colors.black54).withValues(
      alpha: enabled ? 1.0 : 0.6,
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(detail!, style: TextStyle(fontSize: 13, color: muted)),
                  ],
                ],
              ),
            ),
            if (enabled)
              Icon(
                Icons.arrow_forward_ios,
                color: dark ? Colors.white54 : Colors.black45,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }
}
