import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/convos_service.dart';
import 'convos_widgets.dart';

/// A whole day as one continuous chat, live: the child's words on the right,
/// Smarty's replies on the left, a reply growing sentence by sentence while
/// it is being written, and a small time ("16:42") where each play session
/// starts. Follows new messages while the parent is at the bottom; leaves
/// the scroll alone once they scroll up to read.
///
/// One listener for the day's sessions plus one per session for its
/// messages, all cancelled when the page closes.
class DayChatPage extends StatefulWidget {
  final String deviceId;

  /// "YYYY-MM-DD".
  final String day;
  final ConvosSource? source;

  const DayChatPage({
    super.key,
    required this.deviceId,
    required this.day,
    this.source,
  });

  @override
  State<DayChatPage> createState() => _DayChatPageState();
}

class _DayChatPageState extends State<DayChatPage> {
  late final ConvosSource _source = widget.source ?? ConvosService();
  final ScrollController _scroll = ScrollController();

  StreamSubscription<List<Conversation>>? _sessionsSub;
  final Map<String, StreamSubscription<List<ConversationTurn>>> _turnSubs = {};
  List<Conversation>? _sessions;
  final Map<String, List<ConversationTurn>> _turns = {};
  List<DayChatItem> _items = const [];
  Object? _error;

  // Within this many pixels of the end counts as "at the bottom".
  static const double _bottomSlack = 64;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _listen();
  }

  @override
  void dispose() {
    _cancelAll();
    _scroll.dispose();
    super.dispose();
  }

  void _cancelAll() {
    _sessionsSub?.cancel();
    _sessionsSub = null;
    for (final sub in _turnSubs.values) {
      sub.cancel();
    }
    _turnSubs.clear();
  }

  void _listen() {
    _cancelAll();
    _sessionsSub = _source.watchDay(widget.deviceId, widget.day).listen(
      _onSessions,
      onError: _onError,
    );
  }

  void _onError(Object e) {
    debugPrint('Convos: day chat listener error: $e');
    if (!mounted) return;
    _cancelAll();
    setState(() => _error = e);
  }

  // Keep exactly one messages listener per session of the day.
  void _onSessions(List<Conversation> sessions) {
    if (!mounted) return;
    final ids = {for (final s in sessions) s.id};
    for (final gone in _turnSubs.keys.where((id) => !ids.contains(id)).toList()) {
      _turnSubs.remove(gone)?.cancel();
      _turns.remove(gone);
    }
    for (final id in ids) {
      _turnSubs[id] ??= _source.watchTurns(widget.deviceId, id).listen(
        (turns) => _onTurns(id, turns),
        onError: _onError,
      );
    }
    _update(() => _sessions = sessions);
  }

  void _onTurns(String sessionId, List<ConversationTurn> turns) {
    if (!mounted || !_turnSubs.containsKey(sessionId)) return;
    _update(() => _turns[sessionId] = turns);
  }

  void _update(VoidCallback change) {
    final bool follow = _atBottom;
    setState(() {
      change();
      _error = null;
      _items = mergeDayChat(_sessions ?? const [], _turns);
    });
    if (follow) _scrollToBottom();
  }

  void _retry() {
    setState(() {
      _error = null;
      _sessions = null;
      _turns.clear();
      _items = const [];
    });
    _listen();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final bool atBottom = p.pixels >= p.maxScrollExtent - _bottomSlack;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  // After the frame that laid out the new text, so maxScrollExtent includes
  // it.
  void _scrollToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scroll.hasClients) return;
      final double end = _scroll.position.maxScrollExtent;
      if (animate) {
        await _scroll.animateTo(end,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(end);
      }
      _settleAtBottom(5);
    });
  }

  // A lazy list only estimates its extent until its end has been laid out,
  // so the first jump can land short: re-check on the next frames until the
  // end stops moving.
  void _settleAtBottom(int tries) {
    if (tries <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_atBottom) return;
      final p = _scroll.position;
      if (p.maxScrollExtent - p.pixels > 0.5) {
        _scroll.jumpTo(p.maxScrollExtent);
        _settleAtBottom(tries - 1);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) {
      return convosNeedsSignIn(error)
          ? ConvosMessage.signIn(context)
          : ConvosMessage.failed(onRetry: _retry);
    }
    final sessions = _sessions;
    if (sessions == null ||
        (_items.isEmpty && sessions.any((s) => !_turns.containsKey(s.id)))) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const ConvosMessage(
        icon: Icons.forum_outlined,
        message: 'No chats on this day.',
      );
    }
    final items = _items;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => switch (items[i]) {
        SessionStart(:final startedAt) => SessionTimeSeparator(
            key: ValueKey(items[i].key), startedAt: startedAt),
        ChatMessage(:final turn) =>
          TurnBubble(key: ValueKey(items[i].key), turn: turn),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveClock(
      builder: (context, now) {
        // The day is live while any of its sessions is (same `live_until`
        // the day doc carries), so no extra listener for the day doc.
        final bool live = _sessions?.any((s) => s.isLiveAt(now)) ?? false;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(dayLabel(widget.day, now),
                      overflow: TextOverflow.ellipsis),
                ),
                if (live) ...[const SizedBox(width: 10), const LivePill()],
              ],
            ),
          ),
          body: SafeArea(top: false, child: _body(context)),
          floatingActionButton: (_items.isNotEmpty && !_atBottom)
              ? FloatingActionButton.small(
                  tooltip: 'Latest',
                  onPressed: () => _scrollToBottom(animate: true),
                  child: const Icon(Icons.arrow_downward_rounded),
                )
              : null,
        );
      },
    );
  }
}
