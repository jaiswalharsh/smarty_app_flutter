import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

// Chat history read from Firestore, written by the `turn` Cloud Function:
//
//     parents/{uid}/devices/{deviceId}/
//       days/{YYYY-MM-DD}                         → [ConvoDay]
//       conversations/{sessionId}                 → [Conversation]
//       conversations/{sessionId}/turns/{turnId}  → [ConversationTurn]
//
// Models parse plain maps (`doc.data()`), so they are testable without
// Firebase. Timestamps are accepted as Firestore [Timestamp]s, [DateTime]s
// or epoch milliseconds.

/// Firestore value → [DateTime], or null when absent / not a time.
DateTime? _time(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  return null;
}

int _int(Object? v) => v is num ? v.toInt() : 0;

String? _str(Object? v) => v is String ? v : null;

/// Whether something with this `live_until` counts as live at [now].
bool isLiveUntil(DateTime? liveUntil, DateTime now) =>
    liveUntil != null && now.isBefore(liveUntil);

/// One day's summary (`days/{YYYY-MM-DD}`).
class ConvoDay {
  /// "YYYY-MM-DD" — the doc id; the `day` field when present.
  final String day;
  final int conversationCount;
  final int messageCount;
  final DateTime? firstAt;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final DateTime? liveUntil;

  const ConvoDay({
    required this.day,
    this.conversationCount = 0,
    this.messageCount = 0,
    this.firstAt,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.liveUntil,
  });

  factory ConvoDay.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return ConvoDay(
      day: _str(d['day']) ?? id,
      conversationCount: _int(d['conversation_count']),
      messageCount: _int(d['message_count']),
      firstAt: _time(d['first_at']),
      lastMessageAt: _time(d['last_message_at']),
      lastMessagePreview: _str(d['last_message_preview']),
      liveUntil: _time(d['live_until']),
    );
  }

  bool isLiveAt(DateTime now) => isLiveUntil(liveUntil, now);
}

/// One play session (`conversations/{sessionId}`): a run of button presses
/// with no long pause, shown to parents as one "chat".
class Conversation {
  final String id;
  final String? day;
  final DateTime? startedAt;
  final DateTime? lastMessageAt;
  final String? preview;
  final String? lastRole;
  final int messageCount;
  final DateTime? liveUntil;

  const Conversation({
    required this.id,
    this.day,
    this.startedAt,
    this.lastMessageAt,
    this.preview,
    this.lastRole,
    this.messageCount = 0,
    this.liveUntil,
  });

  factory Conversation.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return Conversation(
      id: id,
      day: _str(d['day']),
      startedAt: _time(d['started_at']),
      lastMessageAt: _time(d['last_message_at']),
      preview: _str(d['last_message_preview']),
      lastRole: _str(d['last_message_role']),
      messageCount: _int(d['message_count']),
      liveUntil: _time(d['live_until']),
    );
  }

  bool isLiveAt(DateTime now) => isLiveUntil(liveUntil, now);
}

enum TurnStatus {
  /// The reply is still being written: [ConversationTurn.text] is the text
  /// so far.
  streaming,

  /// Finished (`final` in Firestore).
  complete,

  /// The reply was cut off (the child pressed the button again, or the toy
  /// lost its connection); the text is what was said before that.
  aborted,
}

TurnStatus _status(Object? v) => switch (v) {
      'streaming' => TurnStatus.streaming,
      'aborted' => TurnStatus.aborted,
      _ => TurnStatus.complete, // legacy docs have no status: they are final
    };

/// One message (`turns/{turnId}`): what the child said, or Smarty's reply.
class ConversationTurn {
  final String id;
  final String role; // 'user' | 'assistant'
  final String text;
  final TurnStatus status;

  /// Button press within the session; null for turns from older firmware.
  final int? pressSeq;
  final DateTime? timestamp;
  final DateTime? updatedAt;

  const ConversationTurn({
    required this.id,
    required this.role,
    required this.text,
    this.status = TurnStatus.complete,
    this.pressSeq,
    this.timestamp,
    this.updatedAt,
  });

  factory ConversationTurn.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    final Object? seq = d['press_seq'];
    return ConversationTurn(
      id: id,
      role: _str(d['role']) ?? 'assistant',
      text: _str(d['text']) ?? '',
      status: _status(d['status']),
      pressSeq: seq is num ? seq.toInt() : null,
      timestamp: _time(d['timestamp']),
      updatedAt: _time(d['updated_at']),
    );
  }

  bool get isUser => role == 'user';
  bool get isStreaming => status == TurnStatus.streaming;
  bool get isAborted => status == TurnStatus.aborted;
}

int _roleRank(String role) => switch (role) {
      'user' => 0,
      'assistant' => 1,
      _ => 2,
    };

int _compareTime(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1; // not stamped yet → last
  if (b == null) return -1;
  return a.compareTo(b);
}

/// Transcript order: by button press, the child before Smarty within a press
/// — never by timestamp alone, which a streaming reply would reorder. Turns
/// from older firmware (no `press_seq`) come first, in timestamp order.
int compareTurns(ConversationTurn a, ConversationTurn b) {
  final int? pa = a.pressSeq, pb = b.pressSeq;
  if ((pa == null) != (pb == null)) return pa == null ? -1 : 1;
  if (pa != null && pb != null) {
    final int c = pa.compareTo(pb);
    if (c != 0) return c;
    final int r = _roleRank(a.role).compareTo(_roleRank(b.role));
    if (r != 0) return r;
  }
  final int t = _compareTime(a.timestamp, b.timestamp);
  if (t != 0) return t;
  return a.id.compareTo(b.id);
}

/// [turns] sorted into transcript order (see [compareTurns]).
List<ConversationTurn> sortTurns(Iterable<ConversationTurn> turns) =>
    turns.toList()..sort(compareTurns);

// ---- One chat per day -----------------------------------------------------

/// An entry of a day's chat: a [SessionStart] marker or a [ChatMessage].
sealed class DayChatItem {
  const DayChatItem();

  /// Stable list key.
  String get key;
}

/// Where one play session starts inside the day's chat (shown as a small
/// centered time, "16:42").
class SessionStart extends DayChatItem {
  final String sessionId;
  final DateTime? startedAt;

  const SessionStart(this.sessionId, this.startedAt);

  @override
  String get key => 'start/$sessionId';
}

/// One message of the day's chat.
class ChatMessage extends DayChatItem {
  final String sessionId;
  final ConversationTurn turn;

  const ChatMessage(this.sessionId, this.turn);

  @override
  String get key => 'msg/$sessionId/${turn.id}';
}

/// Session order within a day: by start, oldest first.
int compareSessions(Conversation a, Conversation b) {
  final int t = _compareTime(
      a.startedAt ?? a.lastMessageAt, b.startedAt ?? b.lastMessageAt);
  if (t != 0) return t;
  return a.id.compareTo(b.id);
}

/// A whole day as one chat: [sessions] oldest first, each opened by a
/// [SessionStart] and followed by its messages in transcript order
/// ([compareTurns]). [turnsBySession] holds the latest snapshot of each
/// session's messages, in any order; sessions with no messages loaded yet are
/// left out (they appear when their messages arrive).
List<DayChatItem> mergeDayChat(
  Iterable<Conversation> sessions,
  Map<String, List<ConversationTurn>> turnsBySession,
) {
  final ordered = sessions.toList()..sort(compareSessions);
  final items = <DayChatItem>[];
  for (final s in ordered) {
    final turns = turnsBySession[s.id];
    if (turns == null || turns.isEmpty) continue;
    items.add(SessionStart(s.id, s.startedAt ?? s.lastMessageAt));
    for (final t in sortTurns(turns)) {
      items.add(ChatMessage(s.id, t));
    }
  }
  return items;
}

// ---- Labels (no intl: dependency-free, English) ---------------------------

const List<String> _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Parses a "YYYY-MM-DD" day key into a local calendar date, or null.
DateTime? parseDayKey(String day) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(day);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime(y, mo, d);
}

/// Parent-facing label for a day key: "Today", "Yesterday", "Mon 22 Sep",
/// or "Mon 22 Sep 2025" when not this year. Worked out from the key itself —
/// the server already bucketed the day; the phone never re-buckets.
String dayLabel(String day, DateTime now) {
  final date = parseDayKey(day);
  if (date == null) return day;
  final today = DateTime(now.year, now.month, now.day);
  // Calendar-day difference, immune to DST (both dates taken as UTC).
  final int diff = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(date.year, date.month, date.day))
      .inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final base =
      '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}';
  return date.year == now.year ? base : '$base ${date.year}';
}

/// "16:42" in the phone's local time, or '' when unknown.
String clockTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// "3 chats · 42 messages".
String dayCountsLabel(ConvoDay d) =>
    '${_plural(d.conversationCount, 'chat', 'chats')} · '
    '${_plural(d.messageCount, 'message', 'messages')}';

/// "12 messages".
String messageCountLabel(int n) => _plural(n, 'message', 'messages');
