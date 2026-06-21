import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../services/history_service.dart';
import '../screens/conversation_detail_page.dart';
import '../widgets/account_menu.dart';

/// History tab — the app's first Firestore read (Stitch migration plan
/// Phase 2a). Lists the toy's conversations (newest first); tapping one opens
/// the full transcript. Categorization (Creative Play / Learning / etc.) is a
/// later Phase 2a step and not part of this read.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  final HistoryService _service = HistoryService();
  late Future<String?> _deviceIdFuture;

  @override
  void initState() {
    super.initState();
    _deviceIdFuture = _service.firstDeviceId();
  }

  void _reload() {
    setState(() => _deviceIdFuture = _service.firstDeviceId());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: const [AccountAvatarAction()],
      ),
      body: FutureBuilder<String?>(
        future: _deviceIdFuture,
        builder: (context, deviceSnap) {
          if (deviceSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (deviceSnap.hasError) {
            return _ErrorState(
              message: "Couldn't load your toy.",
              onRetry: _reload,
            );
          }
          final deviceId = deviceSnap.data;
          if (deviceId == null) {
            return const _EmptyState(
              icon: Icons.toys_outlined,
              title: 'No toy registered',
              message:
                  'Register your Smarty to start seeing conversations here.',
            );
          }
          return StreamBuilder<List<Conversation>>(
            stream: _service.watchConversations(deviceId),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorState(
                  message: "Couldn't load conversations.",
                  onRetry: _reload,
                );
              }
              final convos = snap.data ?? const [];
              if (convos.isEmpty) {
                return const _EmptyState(
                  icon: Icons.history_rounded,
                  title: 'No conversations yet',
                  message: "Your toy's conversations will appear here once "
                      'you start chatting.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: convos.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _ConversationTile(
                  conversation: convos[i],
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ConversationDetailPage(
                        deviceId: deviceId,
                        conversation: convos[i],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationTile({required this.conversation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final preview = (conversation.preview?.trim().isNotEmpty ?? false)
        ? conversation.preview!.trim()
        : 'Conversation';
    final count = conversation.messageCount;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.forum_outlined, color: Colors.blue.shade600),
        ),
        title: Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            formatConversationTime(conversation.lastMessageAt),
            if (count > 0) '$count message${count == 1 ? '' : 's'}',
          ].where((s) => s.isNotEmpty).join(' · '),
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
