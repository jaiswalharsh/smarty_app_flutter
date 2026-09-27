import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/auth_service.dart';
import '../../services/ble_manager.dart';
import '../auth/login_page.dart';

/// How often "Live" pills are re-checked against `live_until`.
const Duration liveRecheckInterval = Duration(seconds: 15);

/// Rebuilds [builder] with the current time every [every], so "Live" pills
/// switch off on their own once a chat goes quiet.
class LiveClock extends StatefulWidget {
  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration every;

  const LiveClock({
    super.key,
    required this.builder,
    this.every = liveRecheckInterval,
  });

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}

/// Small green "Live" pill.
class LivePill extends StatelessWidget {
  const LivePill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.green.shade600,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'Live',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Signs out and returns to the sign-in page (same teardown as Settings).
Future<void> signInAgain(BuildContext context) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await BleManager().disconnectAndReset();
  await AuthService().signOut();
  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginPage()),
    (route) => false,
  );
}

/// Centered icon + title + message, with an optional action — the empty,
/// sign-in and "couldn't load" states of the Convos screens.
class ConvosMessage extends StatelessWidget {
  final IconData icon;
  final String? title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const ConvosMessage({
    super.key,
    required this.icon,
    this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  /// "Please sign in again", with a button that does it.
  factory ConvosMessage.signIn(BuildContext context) => ConvosMessage(
        icon: Icons.lock_outline_rounded,
        title: 'Please sign in again',
        message: "Sign in to see your child's chats with Smarty.",
        actionLabel: 'Sign in',
        onAction: () => unawaited(signInAgain(context)),
      );

  /// Anything else that went wrong: plain words and a retry.
  factory ConvosMessage.failed({required VoidCallback onRetry}) =>
      ConvosMessage(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load chats",
        message: 'Check your internet connection and try again.',
        actionLabel: 'Try again',
        onAction: onRetry,
      );

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: muted),
            const SizedBox(height: 16),
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: muted),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Card look of a day row.
class _RowCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _RowCard({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(child: child),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 20,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4)),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _titleLine(BuildContext context, String title, bool live) => Row(
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        if (live) ...[const SizedBox(width: 8), const LivePill()],
      ],
    );

Widget _mutedLine(BuildContext context, String text) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      ),
    );

/// A row of the days list: "Today" + Live pill, "3 chats · 42 messages",
/// and the last thing said.
class DayRow extends StatelessWidget {
  final ConvoDay day;
  final DateTime now;
  final VoidCallback? onTap;

  const DayRow({super.key, required this.day, required this.now, this.onTap});

  @override
  Widget build(BuildContext context) {
    final preview = day.lastMessagePreview?.trim() ?? '';
    return _RowCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleLine(context, dayLabel(day.day, now), day.isLiveAt(now)),
          const SizedBox(height: 4),
          _mutedLine(context, dayCountsLabel(day)),
          if (preview.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

/// The small centered "16:42" where a new play session starts within a
/// day's chat.
class SessionTimeSeparator extends StatelessWidget {
  final DateTime? startedAt;

  const SessionTimeSeparator({super.key, required this.startedAt});

  @override
  Widget build(BuildContext context) {
    final String time = clockTime(startedAt);
    if (time.isEmpty) return const SizedBox(height: 12);
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          time,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: muted,
          ),
        ),
      ),
    );
  }
}

/// One message bubble: the child on the right, Smarty on the left. A reply
/// still being written shows its text so far with a blinking caret; a reply
/// that was cut off gets a small "(interrupted)".
class TurnBubble extends StatelessWidget {
  final ConversationTurn turn;

  const TurnBubble({super.key, required this.turn});

  @override
  Widget build(BuildContext context) {
    final bool isUser = turn.isUser;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isUser
        ? Colors.blue.shade600
        : (dark ? const Color(0xFF2C2C44) : Colors.grey.shade200);
    final Color fg = isUser ? Colors.white : (dark ? Colors.white : Colors.black87);
    final String text = turn.text.trim();

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                text: text,
                children: [
                  if (turn.isStreaming)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: EdgeInsets.only(left: text.isEmpty ? 0 : 2),
                        child: BlinkingCaret(color: fg),
                      ),
                    ),
                ],
              ),
              style: TextStyle(color: fg, fontSize: 15, height: 1.3),
            ),
            if (turn.isAborted)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '(interrupted)',
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.65),
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The blinking caret after a reply that is still being written.
class BlinkingCaret extends StatefulWidget {
  final Color color;

  const BlinkingCaret({super.key, required this.color});

  @override
  State<BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 530),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _blink,
      child: Container(width: 2, height: 16, color: widget.color),
    );
  }
}
