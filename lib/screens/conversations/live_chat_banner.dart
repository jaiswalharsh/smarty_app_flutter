import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/conversations_service.dart';
import 'conversations_widgets.dart';
import 'day_chat_page.dart';

/// Home's one-liner while the child is talking to Smarty right now: "Smarty
/// is talking with your child — tap to watch", opening today's chat.
/// Invisible otherwise, and on any error (Home has its own job).
class LiveChatBanner extends StatefulWidget {
  final ConversationsSource? source;

  const LiveChatBanner({super.key, this.source});

  @override
  State<LiveChatBanner> createState() => _LiveChatBannerState();
}

class _LiveChatBannerState extends State<LiveChatBanner> {
  late final ConversationsSource _source =
      widget.source ?? ConversationsService();
  StreamSubscription<ConvoDay?>? _sub;
  String? _deviceId;
  ConvoDay? _today;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final String? id = await _source.resolveDeviceId();
      if (!mounted || id == null) return;
      _deviceId = id;
      _sub = _source.watchToday(id).listen((day) {
        if (mounted) setState(() => _today = day);
      }, onError: (Object e) {
        debugPrint('Conversations: live banner listener error: $e');
        if (mounted) setState(() => _today = null);
      });
    } catch (e) {
      debugPrint('Conversations: live banner off: $e');
    }
  }

  void _open(ConvoDay day) {
    final String? id = _deviceId;
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          DayChatPage(deviceId: id, day: day.day, source: widget.source),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ConvoDay? today = _today;
    if (today == null) return const SizedBox.shrink();
    return LiveClock(
      builder: (context, now) {
        if (!today.isLiveAt(now)) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Material(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _open(today),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: Colors.green.shade600),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Smarty is talking with your child — tap to watch',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.green.shade900,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 20, color: Colors.green.shade800),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
