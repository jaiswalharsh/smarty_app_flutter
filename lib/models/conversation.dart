import 'package:cloud_firestore/cloud_firestore.dart';

/// A conversation summary, read from
/// `parents/{uid}/devices/{deviceId}/conversations/{convId}`.
///
/// These metadata fields are materialized by the `turn` Cloud Function on each
/// write (see firebase/functions). A conversation that only has a `turns`
/// subcollection but no fields is NOT returned by a collection query, which is
/// why the function writes this summary doc.
class Conversation {
  final String id;
  final DateTime? lastMessageAt;
  final String? preview;
  final String? lastRole;
  final int messageCount;

  Conversation({
    required this.id,
    this.lastMessageAt,
    this.preview,
    this.lastRole,
    this.messageCount = 0,
  });

  factory Conversation.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? const {};
    return Conversation(
      id: doc.id,
      lastMessageAt: (d['last_message_at'] as Timestamp?)?.toDate(),
      preview: d['last_message_preview'] as String?,
      lastRole: d['last_message_role'] as String?,
      messageCount: (d['message_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A single turn within a conversation, from the `turns` subcollection.
class ConversationTurn {
  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime? timestamp;

  ConversationTurn({
    required this.role,
    required this.text,
    this.timestamp,
  });

  bool get isUser => role == 'user';

  factory ConversationTurn.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? const {};
    return ConversationTurn(
      role: (d['role'] as String?) ?? 'assistant',
      text: (d['text'] as String?) ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate(),
    );
  }
}

/// Lightweight, dependency-free timestamp formatting (avoids pulling in intl).
String formatConversationTime(DateTime? dt) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final time = _hm(local);
  final dayDiff = today.difference(that).inDays;
  if (dayDiff == 0) return 'Today $time';
  if (dayDiff == 1) return 'Yesterday $time';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final monthName = months[local.month - 1];
  if (local.year == now.year) return '$monthName ${local.day}, $time';
  return '$monthName ${local.day}, ${local.year}';
}

String _hm(DateTime dt) {
  final isPm = dt.hour >= 12;
  var h = dt.hour % 12;
  if (h == 0) h = 12;
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m ${isPm ? 'PM' : 'AM'}';
}
