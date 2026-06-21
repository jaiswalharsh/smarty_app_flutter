import 'package:flutter/material.dart';

import '../widgets/account_menu.dart';

/// History tab — placeholder empty-state for PR #1 (decided 2026-06-21).
///
/// Raw conversation turns are already persisted server-side, but the app has no
/// Firestore read code yet and turns carry no categories. The first Firestore
/// read + categorization is deferred to Phase 2a, so this stays a placeholder.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: const [AccountAvatarAction()],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.history_rounded, size: 72, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                'No conversations yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                "Your toy's conversations will appear here once you start "
                'chatting.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
