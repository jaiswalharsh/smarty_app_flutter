// Convos screens against a fake data source (no Firebase): the day row, the
// streaming bubble, the one-chat-per-day page, the tab's states and Home's
// live line.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/models/conversation.dart';
import 'package:smarty_app/screens/convos/convos_tab.dart';
import 'package:smarty_app/screens/convos/convos_widgets.dart';
import 'package:smarty_app/screens/convos/day_chat_page.dart';
import 'package:smarty_app/screens/convos/live_chat_banner.dart';
import 'package:smarty_app/services/convos_service.dart';

/// Streams driven by the test; one controller per query.
class FakeConvosSource implements ConvosSource {
  FakeConvosSource({this.deviceId = 'toy1', this.resolveError});

  final String? deviceId;
  final Object? resolveError;
  final days = StreamController<List<ConvoDay>>.broadcast();
  final sessions = StreamController<List<Conversation>>.broadcast();
  final Map<String, StreamController<List<ConversationTurn>>> turns = {};
  final List<String> watchedTurns = [];
  final List<int> dayLimits = [];

  StreamController<List<ConversationTurn>> turnsOf(String sessionId) =>
      turns.putIfAbsent(sessionId, StreamController.broadcast);

  @override
  Future<String?> resolveDeviceId() async {
    if (resolveError != null) throw resolveError!;
    return deviceId;
  }

  @override
  Stream<List<ConvoDay>> watchDays(String deviceId, {int limit = 30}) {
    dayLimits.add(limit);
    return days.stream;
  }

  @override
  Stream<List<Conversation>> watchDay(String deviceId, String day) =>
      sessions.stream;

  @override
  Stream<List<ConversationTurn>> watchTurns(
      String deviceId, String sessionId) {
    watchedTurns.add(sessionId);
    return turnsOf(sessionId).stream;
  }

  @override
  Stream<ConvoDay?> watchToday(String deviceId) =>
      days.stream.map((d) => d.isEmpty ? null : d.first);
}

String todayKey() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

ConversationTurn msg(String id, String role, String text,
        {int? press, TurnStatus status = TurnStatus.complete}) =>
    ConversationTurn(
        id: id, role: role, text: text, status: status, pressSeq: press);

/// Finds the streaming caret.
final Finder caret = find.byType(BlinkingCaret);

/// Unmounts everything, so no LiveClock timer or caret animation is left.
Future<void> unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  group('DayRow', () {
    final now = DateTime(2026, 9, 27, 12);

    Future<void> pumpRow(WidgetTester tester, ConvoDay day) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: DayRow(day: day, now: now, onTap: () {})),
        ));

    testWidgets('today, live: label, counts, preview and the Live pill',
        (tester) async {
      await pumpRow(
        tester,
        ConvoDay(
          day: '2026-09-27',
          conversationCount: 3,
          messageCount: 42,
          lastMessagePreview: 'Why is the sky blue?',
          liveUntil: now.add(const Duration(seconds: 60)),
        ),
      );
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('3 chats · 42 messages'), findsOneWidget);
      expect(find.text('Why is the sky blue?'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
    });

    testWidgets('an earlier day, quiet: no Live pill', (tester) async {
      await pumpRow(
        tester,
        ConvoDay(
          day: '2026-09-22',
          conversationCount: 1,
          messageCount: 2,
          liveUntil: now.subtract(const Duration(seconds: 1)),
        ),
      );
      expect(find.text('Tue 22 Sep'), findsOneWidget);
      expect(find.text('1 chat · 2 messages'), findsOneWidget);
      expect(find.text('Live'), findsNothing);
    });
  });

  group('TurnBubble', () {
    Future<void> pumpBubble(WidgetTester tester, ConversationTurn t) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: TurnBubble(turn: t))));

    testWidgets('streaming: text so far and a caret', (tester) async {
      await pumpBubble(
          tester, msg('a', 'assistant', 'Once upon', status: TurnStatus.streaming));
      expect(find.textContaining('Once upon'), findsOneWidget);
      expect(caret, findsOneWidget);
      await unmount(tester);
    });

    testWidgets('final: no caret; aborted: "(interrupted)"', (tester) async {
      await pumpBubble(tester, msg('a', 'assistant', 'The end.'));
      expect(caret, findsNothing);
      expect(find.text('(interrupted)'), findsNothing);

      await pumpBubble(tester,
          msg('b', 'assistant', 'Once upon a', status: TurnStatus.aborted));
      expect(caret, findsNothing);
      expect(find.text('(interrupted)'), findsOneWidget);
    });

    testWidgets('child on the right, Smarty on the left', (tester) async {
      await pumpBubble(tester, msg('u', 'user', 'Hi'));
      expect(tester.widget<Align>(find.byType(Align).first).alignment,
          Alignment.centerRight);
      await pumpBubble(tester, msg('a', 'assistant', 'Hello'));
      expect(tester.widget<Align>(find.byType(Align).first).alignment,
          Alignment.centerLeft);
    });
  });

  group('DayChatPage', () {
    testWidgets(
        'one chat for the day: sessions in order with their start times, '
        'a reply growing live, then final', (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: DayChatPage(deviceId: 'toy1', day: todayKey(), source: src),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);

      final start1 = DateTime(2026, 9, 27, 9, 5);
      final start2 = DateTime(2026, 9, 27, 16, 42);
      // Newest first, as the query returns them; the second one is live.
      src.sessions.add([
        Conversation(
            id: 's2',
            startedAt: start2,
            liveUntil: DateTime.now().add(const Duration(seconds: 60))),
        Conversation(id: 's1', startedAt: start1),
      ]);
      await tester.pump();
      expect(src.watchedTurns, unorderedEquals(['s1', 's2']));
      expect(find.text('Live'), findsOneWidget);

      // The live session's messages arrive first.
      src.turnsOf('s2').add([
        msg('0001-user', 'user', 'Tell me a story', press: 1),
        msg('0001-assistant', 'assistant', 'Once upon',
            press: 1, status: TurnStatus.streaming),
      ]);
      await tester.pump();
      src.turnsOf('s1').add([
        msg('0001-assistant', 'assistant', 'Good morning!', press: 1),
        msg('0001-user', 'user', 'Hello Smarty', press: 1),
      ]);
      await tester.pump();

      // Morning session above the afternoon one, each under its time.
      double y(String text) => tester.getTopLeft(find.textContaining(text)).dy;
      expect(find.text('09:05'), findsOneWidget);
      expect(find.text('16:42'), findsOneWidget);
      expect(y('09:05'), lessThan(y('Hello Smarty')));
      expect(y('Hello Smarty'), lessThan(y('Good morning!')));
      expect(y('Good morning!'), lessThan(y('16:42')));
      expect(y('16:42'), lessThan(y('Tell me a story')));
      expect(y('Tell me a story'), lessThan(y('Once upon')));
      expect(caret, findsOneWidget);

      // The reply grows in place, then finishes.
      src.turnsOf('s2').add([
        msg('0001-user', 'user', 'Tell me a story', press: 1),
        msg('0001-assistant', 'assistant', 'Once upon a time, a fox',
            press: 1, status: TurnStatus.streaming),
      ]);
      await tester.pump();
      expect(find.textContaining('Once upon a time, a fox'), findsOneWidget);
      expect(caret, findsOneWidget);

      src.turnsOf('s2').add([
        msg('0001-user', 'user', 'Tell me a story', press: 1),
        msg('0001-assistant', 'assistant', 'Once upon a time, a fox slept.',
            press: 1),
      ]);
      await tester.pump();
      expect(find.textContaining('a fox slept.'), findsOneWidget);
      expect(caret, findsNothing);

      await unmount(tester);
    });

    testWidgets('follows new messages at the bottom, not after scrolling up',
        (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: DayChatPage(deviceId: 'toy1', day: '2026-09-20', source: src),
      ));
      src.sessions.add([Conversation(id: 's1', startedAt: DateTime(2026))]);
      await tester.pump();
      List<ConversationTurn> upTo(int n) => [
            for (int i = 1; i <= n; i++) ...[
              msg('$i-user', 'user', 'Question $i', press: i),
              msg('$i-assistant', 'assistant', 'Answer $i', press: i),
            ],
          ];
      // A few frames: the page re-checks the end until the lazy list's
      // extent stops growing.
      Future<void> frames() async {
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      ScrollPosition pos() =>
          tester.state<ScrollableState>(find.byType(Scrollable)).position;

      src.turnsOf('s1').add(upTo(30));
      await frames();
      expect(pos().maxScrollExtent, greaterThan(0));
      expect(pos().pixels, pos().maxScrollExtent); // opened at the latest

      src.turnsOf('s1').add(upTo(31));
      await frames();
      expect(pos().pixels, pos().maxScrollExtent); // followed

      pos().jumpTo(0); // the parent scrolls up to read
      await tester.pump();
      src.turnsOf('s1').add(upTo(32));
      await frames();
      expect(pos().pixels, 0); // left alone
      expect(find.byTooltip('Latest'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a session that disappears stops being listened to',
        (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: DayChatPage(deviceId: 'toy1', day: '2026-09-20', source: src),
      ));
      src.sessions.add([Conversation(id: 's1', startedAt: DateTime(2026))]);
      await tester.pump();
      expect(src.turnsOf('s1').hasListener, isTrue);
      src.sessions.add([]);
      await tester.pump();
      expect(src.turnsOf('s1').hasListener, isFalse);
      expect(find.text('No chats on this day.'), findsOneWidget);
      await unmount(tester);
      expect(src.sessions.hasListener, isFalse);
    });

    testWidgets('permission denied → sign-in prompt, not an error',
        (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: DayChatPage(deviceId: 'toy1', day: '2026-09-20', source: src),
      ));
      src.sessions.addError(FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied'));
      await tester.pump();
      expect(find.text('Please sign in again'), findsOneWidget);
      expect(find.textContaining('permission'), findsNothing);
      await unmount(tester);
    });
  });

  group('ConvosTab', () {
    Future<void> pumpTab(WidgetTester tester, FakeConvosSource src) async {
      await tester.pumpWidget(MaterialApp(home: ConvosTab(source: src)));
      await tester.pump(); // device resolved
    }

    testWidgets('no chats yet: the empty-state copy', (tester) async {
      final src = FakeConvosSource();
      await pumpTab(tester, src);
      src.days.add([]);
      await tester.pump();
      expect(
          find.text('When your child talks to Smarty, their chats will show '
              'up here.'),
          findsOneWidget);
      await unmount(tester);
    });

    testWidgets('days newest first; tapping one opens that day as one chat',
        (tester) async {
      final src = FakeConvosSource();
      await pumpTab(tester, src);
      expect(src.dayLimits, [30]);
      src.days.add([
        ConvoDay(
          day: todayKey(),
          conversationCount: 2,
          messageCount: 9,
          liveUntil: DateTime.now().add(const Duration(seconds: 60)),
        ),
        const ConvoDay(day: '2025-12-31', conversationCount: 1, messageCount: 4),
      ]);
      await tester.pump();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Wed 31 Dec 2025'), findsOneWidget);
      expect(find.text('Show earlier days'), findsNothing); // fewer than 30

      await tester.tap(find.text('Today'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // route transition
      expect(find.byType(DayChatPage), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a full page offers earlier days', (tester) async {
      final src = FakeConvosSource();
      await pumpTab(tester, src);
      src.days.add([
        for (int i = 1; i <= 30; i++)
          ConvoDay(day: '2025-01-${i.toString().padLeft(2, '0')}'),
      ]);
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Show earlier days'), 300);
      await tester.tap(find.text('Show earlier days'));
      await tester.pump();
      expect(src.dayLimits, [30, 60]);
      await unmount(tester);
    });

    testWidgets('no toy on the account: points to setup', (tester) async {
      await pumpTab(tester, FakeConvosSource(deviceId: null));
      expect(find.text('No chats yet'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('signed out: sign-in prompt', (tester) async {
      await pumpTab(
          tester, FakeConvosSource(resolveError: const ConvosSignedOut()));
      expect(find.text('Please sign in again'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('other failures: plain words and a retry', (tester) async {
      await pumpTab(tester,
          FakeConvosSource(resolveError: FirebaseException(plugin: 'x', code: 'unavailable')));
      expect(find.text("Couldn't load chats"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('listens only while it is the visible tab', (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(
          MaterialApp(home: ConvosTab(source: src, isActive: false)));
      await tester.pump();
      expect(src.days.hasListener, isFalse);
      await tester.pumpWidget(
          MaterialApp(home: ConvosTab(source: src, isActive: true)));
      await tester.pump();
      expect(src.days.hasListener, isTrue);
      await tester.pumpWidget(
          MaterialApp(home: ConvosTab(source: src, isActive: false)));
      expect(src.days.hasListener, isFalse);
      await unmount(tester);
    });
  });

  group('Home live line', () {
    testWidgets('shows while today is live, and opens today\'s chat',
        (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LiveChatBanner(source: src)),
      ));
      await tester.pump();
      const line = 'Smarty is talking with your child — tap to watch';
      expect(find.text(line), findsNothing);

      src.days.add([
        ConvoDay(
            day: todayKey(),
            liveUntil: DateTime.now().add(const Duration(seconds: 60))),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text(line), findsOneWidget);

      await tester.tap(find.text(line));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // route transition
      expect(find.byType(DayChatPage), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('hidden when the day went quiet, or on errors',
        (tester) async {
      final src = FakeConvosSource();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LiveChatBanner(source: src)),
      ));
      await tester.pump();
      src.days.add([
        ConvoDay(
            day: todayKey(),
            liveUntil: DateTime.now().subtract(const Duration(seconds: 1))),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.byType(LiveClock), findsOneWidget); // got the day…
      expect(find.byType(InkWell), findsNothing); // …but it's quiet

      final broken = FakeConvosSource(resolveError: Exception('offline'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LiveChatBanner(source: broken)),
      ));
      await tester.pump();
      expect(find.byType(InkWell), findsNothing);
      await unmount(tester);
    });
  });
}
