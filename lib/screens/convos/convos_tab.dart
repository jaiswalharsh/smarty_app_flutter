import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/convos_service.dart';
import 'convos_widgets.dart';
import 'day_chat_page.dart';

/// The Convos tab: the days your child talked with Smarty, newest first,
/// with a Live pill on the day a chat is happening. Tapping a day opens that
/// whole day as one chat.
///
/// Lives in the shell's IndexedStack, so it stays mounted: it only listens
/// while [isActive] (the visible tab) and keeps the last list meanwhile.
class ConvosTab extends StatefulWidget {
  final bool isActive;
  final ConvosSource? source;

  const ConvosTab({super.key, this.isActive = true, this.source});

  @override
  State<ConvosTab> createState() => _ConvosTabState();
}

enum _DeviceState { unknown, loading, none, found, signIn, failed }

class _ConvosTabState extends State<ConvosTab> {
  static const int pageSize = 30;

  late final ConvosSource _source = widget.source ?? ConvosService();
  _DeviceState _deviceState = _DeviceState.unknown;
  String? _deviceId;
  int _resolveGen = 0;

  StreamSubscription<List<ConvoDay>>? _sub;
  List<ConvoDay>? _days;
  Object? _error;
  int _limit = pageSize;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _deviceState = _DeviceState.loading;
      unawaited(_resolve());
    }
  }

  @override
  void didUpdateWidget(ConvosTab old) {
    super.didUpdateWidget(old);
    if (widget.isActive == old.isActive) return;
    if (!widget.isActive) {
      _stopListening();
    } else if (_deviceState == _DeviceState.found) {
      _listen();
    } else if (_deviceState != _DeviceState.loading) {
      // Not found before (no toy yet, signed out, offline): look again —
      // the parent may just have finished setting up.
      _deviceState = _DeviceState.loading; // rebuilt right after this anyway
      unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  Future<void> _resolve() async {
    final int gen = ++_resolveGen;
    if (_deviceState != _DeviceState.loading) {
      setState(() => _deviceState = _DeviceState.loading);
    }
    String? id;
    _DeviceState next;
    try {
      id = await _source.resolveDeviceId();
      next = id == null ? _DeviceState.none : _DeviceState.found;
    } catch (e) {
      debugPrint('Convos: could not find the toy: $e');
      next = convosNeedsSignIn(e) ? _DeviceState.signIn : _DeviceState.failed;
    }
    if (!mounted || gen != _resolveGen) return;
    final bool changed = id != _deviceId;
    setState(() {
      _deviceState = next;
      _deviceId = id;
      if (changed) {
        _days = null;
        _limit = pageSize;
      }
    });
    if (next == _DeviceState.found && widget.isActive) {
      _listen();
    } else {
      _stopListening();
    }
  }

  void _listen() {
    final String? id = _deviceId;
    if (id == null) return;
    _sub?.cancel();
    _sub = _source.watchDays(id, limit: _limit).listen((days) {
      if (!mounted) return;
      setState(() {
        _days = days;
        _error = null;
      });
    }, onError: (Object e) {
      debugPrint('Convos: days listener error: $e');
      if (mounted) setState(() => _error = e);
    });
  }

  void _stopListening() {
    _sub?.cancel();
    _sub = null;
  }

  void _showMore() {
    setState(() => _limit += pageSize);
    _listen(); // keeps showing the current list until the longer one lands
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    await _resolve();
  }

  void _openDay(ConvoDay day) {
    final id = _deviceId;
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          DayChatPage(deviceId: id, day: day.day, source: widget.source),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: _buildBody(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Every state is scrollable, so pull-to-refresh works on all of them.
  Widget _scrollableMessage(Widget message) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: message,
          ),
        ),
      );

  Widget _buildBody(BuildContext context) {
    switch (_deviceState) {
      case _DeviceState.unknown:
      case _DeviceState.loading:
        if (_days == null) {
          return _scrollableMessage(
              const Center(child: CircularProgressIndicator()));
        }
        break; // re-checking with a list on screen: keep showing it
      case _DeviceState.signIn:
        return _scrollableMessage(ConvosMessage.signIn(context));
      case _DeviceState.failed:
        return _scrollableMessage(
            ConvosMessage.failed(onRetry: () => unawaited(_resolve())));
      case _DeviceState.none:
        return _scrollableMessage(const ConvosMessage(
          icon: Icons.toys_outlined,
          title: 'No chats yet',
          message: "Finish setting up Smarty on the Home tab, and your "
              "child's chats will show up here.",
        ));
      case _DeviceState.found:
        break;
    }

    final error = _error;
    if (error != null) {
      return _scrollableMessage(convosNeedsSignIn(error)
          ? ConvosMessage.signIn(context)
          : ConvosMessage.failed(onRetry: () {
              setState(() => _error = null);
              _listen();
            }));
    }
    final days = _days;
    if (days == null) {
      return _scrollableMessage(
          const Center(child: CircularProgressIndicator()));
    }
    if (days.isEmpty) {
      return _scrollableMessage(const ConvosMessage(
        icon: Icons.forum_outlined,
        message: 'When your child talks to Smarty, their chats will show '
            'up here.',
      ));
    }

    final bool mayHaveMore = days.length >= _limit;
    return LiveClock(
      builder: (context, now) => ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: days.length + (mayHaveMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == days.length) {
            return Center(
              child: TextButton(
                onPressed: _showMore,
                child: const Text('Show earlier days'),
              ),
            );
          }
          return DayRow(
            day: days[i],
            now: now,
            onTap: () => _openDay(days[i]),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Convos',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: dark ? const Color(0xFFFF6EC7) : Colors.blue.shade800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'What your child and Smarty talked about',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
