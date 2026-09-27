// Conversations models: parsing, live window, transcript order, day labels
// and the one-chat-per-day merge. Pure Dart — no Firebase.
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/models/conversation.dart';

ConversationTurn turn(
  String id, {
  String role = 'assistant',
  String text = '',
  String? status,
  int? pressSeq,
  DateTime? ts,
}) =>
    ConversationTurn.fromMap(id, {
      'role': role,
      'text': text,
      if (status != null) 'status': status,
      if (pressSeq != null) 'press_seq': pressSeq,
      if (ts != null) 'timestamp': Timestamp.fromDate(ts),
    });

void main() {
  final t0 = DateTime.utc(2026, 9, 27, 14, 0);

  group('parsing', () {
    test('turn: streaming / final / aborted, with press_seq', () {
      final s = ConversationTurn.fromMap('0007-assistant', {
        'role': 'assistant',
        'text': 'Once upon',
        'status': 'streaming',
        'chunk_seq': 3,
        'press_seq': 7,
        'timestamp': Timestamp.fromDate(t0),
        'updated_at': Timestamp.fromDate(t0.add(const Duration(seconds: 2))),
        'device_timestamp': 1758880000,
      });
      expect(s.isStreaming, isTrue);
      expect(s.isAborted, isFalse);
      expect(s.isUser, isFalse);
      expect(s.pressSeq, 7);
      expect(s.text, 'Once upon');
      expect(s.timestamp!.toUtc(), t0);
      expect(s.updatedAt!.toUtc(), t0.add(const Duration(seconds: 2)));

      expect(turn('a', status: 'final').status, TurnStatus.complete);
      expect(turn('b', status: 'aborted').isAborted, isTrue);
      expect(turn('c', role: 'user').isUser, isTrue);
    });

    test('turn from older firmware: no press_seq, no status → final', () {
      final legacy = ConversationTurn.fromMap('autoId', {
        'role': 'user',
        'text': 'Hi Smarty',
        'timestamp': Timestamp.fromDate(t0),
      });
      expect(legacy.pressSeq, isNull);
      expect(legacy.status, TurnStatus.complete);
      expect(legacy.isUser, isTrue);
    });

    test('turn with missing / odd fields does not throw', () {
      final t = ConversationTurn.fromMap('x', {'press_seq': 'nope'});
      expect(t.role, 'assistant');
      expect(t.text, '');
      expect(t.pressSeq, isNull);
      expect(ConversationTurn.fromMap('y', null).text, '');
    });

    test('day doc', () {
      final d = ConvoDay.fromMap('2026-09-27', {
        'day': '2026-09-27',
        'conversation_count': 3,
        'message_count': 42,
        'first_at': Timestamp.fromDate(t0),
        'last_message_at': Timestamp.fromDate(t0),
        'last_message_preview': 'Why is the sky blue?',
        'live_until': Timestamp.fromDate(t0.add(const Duration(seconds: 90))),
      });
      expect(d.day, '2026-09-27');
      expect(d.conversationCount, 3);
      expect(d.messageCount, 42);
      expect(d.lastMessagePreview, 'Why is the sky blue?');
      expect(dayCountsLabel(d), '3 chats · 42 messages');
      expect(
          dayCountsLabel(const ConvoDay(
              day: '2026-09-27', conversationCount: 1, messageCount: 1)),
          '1 chat · 1 message');
      // Doc id stands in for a missing `day` field.
      expect(ConvoDay.fromMap('2026-09-26', {}).day, '2026-09-26');
    });

    test('conversation doc', () {
      final c = Conversation.fromMap('1758880000', {
        'session_id': '1758880000',
        'day': '2026-09-27',
        'started_at': Timestamp.fromDate(t0),
        'last_message_at': Timestamp.fromDate(t0),
        'last_message_preview': 'Hello',
        'last_message_role': 'assistant',
        'message_count': 4,
      });
      expect(c.id, '1758880000');
      expect(c.day, '2026-09-27');
      expect(c.startedAt!.toUtc(), t0);
      expect(c.messageCount, 4);
      expect(c.liveUntil, isNull);
    });
  });

  group('isLive', () {
    test('live strictly before live_until, never without it', () {
      final until = t0.add(const Duration(seconds: 90));
      final d = ConvoDay(day: '2026-09-27', liveUntil: until);
      expect(d.isLiveAt(t0), isTrue);
      expect(d.isLiveAt(until.subtract(const Duration(seconds: 1))), isTrue);
      expect(d.isLiveAt(until), isFalse);
      expect(d.isLiveAt(until.add(const Duration(minutes: 5))), isFalse);
      expect(const ConvoDay(day: '2026-09-27').isLiveAt(t0), isFalse);
      expect(Conversation(id: 's', liveUntil: until).isLiveAt(t0), isTrue);
    });
  });

  group('turn order', () {
    test('by press, child before Smarty — not by timestamp', () {
      // The reply's first write can land before the child's final text.
      final turns = [
        turn('0002-assistant', pressSeq: 2, ts: t0),
        turn('0001-assistant', pressSeq: 1, ts: t0),
        turn('0002-user', role: 'user', pressSeq: 2,
            ts: t0.add(const Duration(seconds: 5))),
        turn('0001-user', role: 'user', pressSeq: 1,
            ts: t0.add(const Duration(seconds: 9))),
      ];
      expect(sortTurns(turns).map((t) => t.id), [
        '0001-user',
        '0001-assistant',
        '0002-user',
        '0002-assistant',
      ]);
    });

    test('turns without press_seq fall back to timestamp', () {
      final turns = [
        turn('b', role: 'assistant', ts: t0.add(const Duration(seconds: 3))),
        turn('c', role: 'user', ts: t0.add(const Duration(seconds: 10))),
        turn('a', role: 'user', ts: t0),
      ];
      expect(sortTurns(turns).map((t) => t.id), ['a', 'b', 'c']);
    });

    test('mixed: older-firmware turns first, then by press', () {
      final turns = [
        turn('0001-user', role: 'user', pressSeq: 1, ts: t0),
        turn('legacy', ts: t0.add(const Duration(hours: 1))),
      ];
      expect(sortTurns(turns).map((t) => t.id), ['legacy', '0001-user']);
    });
  });

  group('day labels', () {
    final now = DateTime(2026, 9, 27, 10, 30); // a Sunday

    test('today / yesterday', () {
      expect(dayLabel('2026-09-27', now), 'Today');
      expect(dayLabel('2026-09-26', now), 'Yesterday');
      // Just after midnight still counts calendar days.
      expect(dayLabel('2026-09-26', DateTime(2026, 9, 27, 0, 1)), 'Yesterday');
      expect(dayLabel('2026-09-26', DateTime(2026, 9, 26, 23, 59)), 'Today');
    });

    test('this year: weekday + date, no year', () {
      expect(dayLabel('2026-09-22', now), 'Tue 22 Sep');
      expect(dayLabel('2026-01-01', now), 'Thu 1 Jan');
    });

    test('other year: with the year', () {
      expect(dayLabel('2025-12-31', now), 'Wed 31 Dec 2025');
      expect(dayLabel('2025-12-31', DateTime(2026, 1, 1)), 'Yesterday');
    });

    test('across a DST change', () {
      // Europe: clocks go back on 25 Oct 2026.
      expect(dayLabel('2026-10-25', DateTime(2026, 10, 26, 0, 30)),
          'Yesterday');
    });

    test('not a day key: shown as is', () {
      expect(dayLabel('garbage', now), 'garbage');
      expect(parseDayKey('2026-13-01'), isNull);
    });

    test('clock time', () {
      expect(clockTime(DateTime(2026, 9, 27, 16, 42)), '16:42');
      expect(clockTime(DateTime(2026, 9, 27, 7, 5)), '07:05');
      expect(clockTime(null), '');
    });
  });

  group('one chat per day', () {
    final morning = Conversation(id: '1000', startedAt: t0);
    final afternoon =
        Conversation(id: '2000', startedAt: t0.add(const Duration(hours: 3)));

    List<String> keys(List<DayChatItem> items) => [
          for (final i in items)
            switch (i) {
              SessionStart(:final sessionId) => '[$sessionId]',
              ChatMessage(:final turn) => turn.id,
            },
        ];

    test('sessions oldest first, each opened by its start time', () {
      // Newest-first from the query, and the afternoon's messages arrived
      // before the morning's.
      final turns = <String, List<ConversationTurn>>{};
      turns['2000'] = [
        turn('0001-assistant', pressSeq: 1),
        turn('0001-user', role: 'user', pressSeq: 1),
      ];
      turns['1000'] = [
        turn('0002-user', role: 'user', pressSeq: 2),
        turn('0001-user', role: 'user', pressSeq: 1),
        turn('0001-assistant', pressSeq: 1),
      ];
      final items = mergeDayChat([afternoon, morning], turns);
      expect(keys(items), [
        '[1000]', '0001-user', '0001-assistant', '0002-user',
        '[2000]', '0001-user', '0001-assistant',
      ]);
      final first = items.first as SessionStart;
      expect(first.startedAt, t0);
      // Keys stay unique across sessions that reuse turn ids.
      expect(items.map((i) => i.key).toSet().length, items.length);
    });

    test('a session whose messages have not arrived yet is left out', () {
      final items = mergeDayChat([morning, afternoon], {
        '1000': [turn('0001-user', role: 'user', pressSeq: 1)],
      });
      expect(keys(items), ['[1000]', '0001-user']);
      expect(mergeDayChat([morning], {}), isEmpty);
    });

    test('older-firmware session (no press_seq) orders by timestamp', () {
      final items = mergeDayChat([morning], {
        '1000': [
          turn('y', ts: t0.add(const Duration(seconds: 4))),
          turn('x', role: 'user', ts: t0),
        ],
      });
      expect(keys(items), ['[1000]', 'x', 'y']);
    });

    test('a streaming update replaces the reply in place', () {
      final turns = <String, List<ConversationTurn>>{
        '1000': [
          turn('0001-user', role: 'user', pressSeq: 1, text: 'Tell a story'),
          turn('0001-assistant',
              pressSeq: 1, status: 'streaming', text: 'Once upon'),
        ],
        '2000': [turn('0001-user', role: 'user', pressSeq: 1, text: 'Hi')],
      };
      final before = mergeDayChat([morning, afternoon], turns);
      turns['1000'] = [
        turn('0001-user', role: 'user', pressSeq: 1, text: 'Tell a story'),
        turn('0001-assistant',
            pressSeq: 1, status: 'final', text: 'Once upon a time.'),
      ];
      final after = mergeDayChat([morning, afternoon], turns);
      expect(keys(after), keys(before));
      final reply = after[2] as ChatMessage;
      expect(reply.turn.text, 'Once upon a time.');
      expect(reply.turn.isStreaming, isFalse);
      expect(after[2].key, before[2].key);
    });
  });
}
