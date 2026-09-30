import 'package:flutter/material.dart';

import '../services/ble_manager.dart';
import 'forget_toy.dart';

/// Subtitle of the Wi-Fi row while Smarty isn't connected (its Wi-Fi is set
/// over Bluetooth, so the row waits until Smarty is nearby).
const String wifiRowAwayDetail = 'Available when Smarty is nearby';

/// What the Wi-Fi row offers at its end, besides opening the Wi-Fi page.
enum WifiRowAction {
  /// Nothing extra: a chevron (nothing at all while Smarty is away).
  none,

  /// Smarty isn't on Wi-Fi: a "Set up" button.
  setUp,

  /// The status didn't come, or Smarty is still joining: a refresh button.
  checkAgain,
}

/// What Home's Wi-Fi row shows. See [wifiRowInfo].
@immutable
class WifiRowInfo {
  const WifiRowInfo(
    this.detail, {
    this.icon = Icons.wifi,
    this.action = WifiRowAction.none,
  });

  /// The row's subtitle.
  final String detail;
  final IconData icon;
  final WifiRowAction action;

  /// Smarty isn't on Wi-Fi (the row's icon turns orange).
  bool get isProblem => action == WifiRowAction.setUp;

  @override
  String toString() => 'WifiRowInfo($detail, $action)';
}

/// Home's Wi-Fi row from the raw `wifi` status Smarty last reported. Pure
/// (tests). [connected]: Smarty is connected ([ToyPhase.connected]).
/// [statusStalled]: Smarty never answered the status read.
///
/// The network's name once Smarty is on Wi-Fi; otherwise a few plain words
/// (the header's status line says why), with a "Set up" button when Smarty
/// isn't on Wi-Fi and a refresh button while the status is stuck or Smarty
/// is still joining.
WifiRowInfo wifiRowInfo({
  required bool connected,
  required String wifi,
  bool statusStalled = false,
}) {
  if (!connected) return const WifiRowInfo(wifiRowAwayDetail);
  if (statusStalled) {
    return const WifiRowInfo(
      "Couldn't check",
      action: WifiRowAction.checkAgain,
    );
  }
  final String status = wifi.trim();
  if (status.isEmpty || status == 'Unknown' || status == 'NotConnected') {
    return const WifiRowInfo('Checking…');
  }
  if (status == 'Initializing' || status == 'Reconnecting') {
    // Joining can take a while (the toy retries for ~45 s) and BleManager
    // keeps re-reading meanwhile — but offer a manual re-check too.
    return const WifiRowInfo('Joining…', action: WifiRowAction.checkAgain);
  }
  if (BleManager.isWifiConnectedStatus(status)) return WifiRowInfo(status);
  // Just the state: the card's header already says why (wrong password,
  // router off…), so the row doesn't repeat it.
  return WifiRowInfo(
    status == 'No credentials' ? 'Not set up yet' : 'Not connected',
    icon: Icons.wifi_off,
    action: WifiRowAction.setUp,
  );
}

/// Home's one Smarty card: a header (the toy's picture, its name, its 4-char
/// code as small text, a one-line [status] with an optional small spinner,
/// and a "⋯" button for Forget this Smarty / Remove from my account), then
/// [rows], then an optional
/// [footer] (what to do next: a message and buttons).
class SmartyCard extends StatelessWidget {
  const SmartyCard({
    super.key,
    required this.name,
    this.code,
    required this.status,
    this.busy = false,
    required this.onForget,
    this.onRemove,
    required this.rows,
    this.footer = const [],
  });

  /// The toy's name ("Smarty").
  final String name;

  /// The toy's 4-character code ("AB12"), or null.
  final String? code;

  /// One-line status under the name.
  final String status;

  /// Shows a small spinner before [status].
  final bool busy;

  /// "⋯" → "Forget this Smarty" (should ask first: see [confirmAndForgetToy]).
  final VoidCallback onForget;

  /// "⋯" → "Remove from my account" (should ask first: see
  /// [confirmAndRemoveToy]); not offered when null.
  final VoidCallback? onRemove;

  /// [SmartyCardRow]s, under the header.
  final List<Widget> rows;

  /// Under the rows, behind a divider; nothing when empty.
  final List<Widget> footer;

  static Color background(bool dark) =>
      dark ? const Color(0xFF2C2C44) : Colors.blue.shade50;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color text = dark ? Colors.white : Colors.black87;
    final Color muted = dark ? Colors.white70 : Colors.black54;
    final Color accent = dark ? const Color(0xFFFF6EC7) : Colors.blue;
    final Widget divider = Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: dark ? Colors.white12 : Colors.black12,
    );

    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Container(
        color: background(dark),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: dark ? const Color(0xFF3A3A5A) : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 30,
                      height: 30,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: text,
                                ),
                              ),
                            ),
                            if (code != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                code!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: dark ? Colors.white54 : Colors.black45,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (busy) ...[
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                status,
                                style: TextStyle(fontSize: 14, color: muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  ToyMoreButton(
                    color: muted,
                    onForget: onForget,
                    onRemove: onRemove,
                  ),
                ],
              ),
            ),
            divider,
            const SizedBox(height: 4),
            ...rows,
            if (footer.isNotEmpty) ...[
              const SizedBox(height: 4),
              divider,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: footer,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One tappable line in [SmartyCard]: icon, label, optional detail, and a
/// chevron — or [trailing] in its place. Greyed out and not tappable when
/// [onTap] is null.
class SmartyCardRow extends StatelessWidget {
  const SmartyCardRow({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.onTap,
    this.iconColor,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback? onTap;

  /// The icon's colour when enabled (default: the label's).
  final Color? iconColor;

  /// Shown at the end instead of the chevron (e.g. a "Set up" button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool enabled = onTap != null;
    final Color base = dark ? Colors.white : Colors.black87;
    final Color fg = enabled ? base : base.withValues(alpha: 0.4);
    final Color mutedBase = dark ? Colors.white70 : Colors.black54;
    final Color muted =
        enabled ? mutedBase : mutedBase.withValues(alpha: mutedBase.a * 0.6);
    final Widget? end =
        trailing ??
        (enabled
            ? Icon(
              Icons.arrow_forward_ios,
              color: dark ? Colors.white54 : Colors.black45,
              size: 16,
            )
            : null);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(icon, color: enabled ? (iconColor ?? fg) : fg, size: 22),
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
            if (end != null) ...[const SizedBox(width: 8), end],
          ],
        ),
      ),
    );
  }
}
