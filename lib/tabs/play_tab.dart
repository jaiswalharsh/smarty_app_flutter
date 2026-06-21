import 'package:flutter/material.dart';

import '../widgets/account_menu.dart';

/// Play tab — story-launcher placeholder for PR #1 (decided, plan §0 / §6.5).
///
/// Eventual purpose: parent picks a story/game and the app tells the toy to
/// start it. That needs a net-new app→toy command characteristic + firmware
/// handler (Phase 2), so for now the cards are unwired and not the default tab.
class PlayTab extends StatelessWidget {
  const PlayTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
        actions: const [AccountAvatarAction()],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Start something fun',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Pick a story or game for Smarty to start. (Coming soon)',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
              const _StoryCard(
                icon: Icons.nightlight_round,
                color: Colors.indigo,
                title: 'Bedtime Story',
                subtitle: 'A calm tale to wind down',
              ),
              const SizedBox(height: 12),
              const _StoryCard(
                icon: Icons.explore,
                color: Colors.orange,
                title: 'Adventure Tale',
                subtitle: 'An exciting journey',
              ),
              const SizedBox(height: 12),
              const _StoryCard(
                icon: Icons.school,
                color: Colors.green,
                title: 'Learning Quiz',
                subtitle: 'Fun questions to learn',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _StoryCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        subtitle: Text(subtitle),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'Soon',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Story launcher coming soon')),
        ),
      ),
    );
  }
}
