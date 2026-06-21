import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../services/history_service.dart';

/// Read-only transcript of a single conversation's turns, rendered as chat
/// bubbles (user right, assistant left).
class ConversationDetailPage extends StatefulWidget {
  final String deviceId;
  final Conversation conversation;

  const ConversationDetailPage({
    super.key,
    required this.deviceId,
    required this.conversation,
  });

  @override
  State<ConversationDetailPage> createState() => _ConversationDetailPageState();
}

class _ConversationDetailPageState extends State<ConversationDetailPage> {
  final HistoryService _service = HistoryService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(formatConversationTime(widget.conversation.lastMessageAt)),
      ),
      body: StreamBuilder<List<ConversationTurn>>(
        stream: _service.watchTurns(widget.deviceId, widget.conversation.id),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't load this conversation.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            );
          }
          final turns = snap.data ?? const [];
          if (turns.isEmpty) {
            return Center(
              child: Text(
                'No messages in this conversation.',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            itemCount: turns.length,
            itemBuilder: (context, i) => _TurnBubble(turn: turns[i]),
          );
        },
      ),
    );
  }
}

class _TurnBubble extends StatelessWidget {
  final ConversationTurn turn;

  const _TurnBubble({required this.turn});

  @override
  Widget build(BuildContext context) {
    final isUser = turn.isUser;
    final bg = isUser ? Colors.blue.shade600 : Colors.grey.shade200;
    final fg = isUser ? Colors.white : Colors.black87;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
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
        child: Text(
          turn.text,
          style: TextStyle(color: fg, fontSize: 15, height: 1.3),
        ),
      ),
    );
  }
}
