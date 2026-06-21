import 'package:flutter/material.dart';

import '../screens/user_context_page.dart';
import '../widgets/account_menu.dart';

/// Memory tab — for PR #1 this is the existing single User-Context editor
/// surfaced as "what your toy remembers". Structured memory (interests,
/// friends, stories, memory bank) is net-new backend work, gated to Phase 2b.
class MemoryTab extends StatelessWidget {
  const MemoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: const [AccountAvatarAction()],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What your toy remembers',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Personalize how Smarty talks to your child.',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.pink.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.chat_bubble_outline,
                        color: Colors.pink),
                  ),
                  title: const Text(
                    'About your child',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                  subtitle: const Text('Tell Smarty what it should know'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UserContextPage()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
