import 'package:flutter/material.dart';

import '../main.dart';
import '../services/auth_service.dart';

/// Top-bar avatar that opens the account menu (Account / About / Help / Sign Out).
///
/// Re-homed here from the retired Settings tab as part of the 4-tab IA
/// (Stitch migration plan §4). Light-only — the old Appearance/dark toggle is
/// intentionally dropped (dark mode parked, §2.2).
class AccountAvatarAction extends StatelessWidget {
  const AccountAvatarAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.account_circle),
      tooltip: 'Account',
      onPressed: () => _showAccountMenu(context),
    );
  }

  void _showAccountMenu(BuildContext context) {
    final email = AuthService().currentUser?.email ?? 'Not signed in';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.person_outline, color: Colors.indigo),
                title: Text(email),
                subtitle: const Text('Manage your account'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showAccountDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.smart_toy, color: Colors.purple),
                title: const Text('About Smarty'),
                subtitle: const Text('Learn more about your Smarty toy'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showAboutDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.help_outline, color: Colors.green),
                title: const Text('Need Help?'),
                subtitle: const Text('Get help with your Smarty toy'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showHelpDialog(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // Account dialog with sign-out.
  void _showAccountDialog(BuildContext context) {
    final email = AuthService().currentUser?.email ?? 'Not signed in';
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.person, color: Colors.indigo, size: 24),
              SizedBox(width: 8),
              Text('Account'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(email, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                'Signed in',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await AuthService().signOut();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const SplashScreen()),
                    (route) => false,
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Sign Out'),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.smart_toy, color: Colors.purple, size: 24),
              SizedBox(width: 8),
              Text('About Smarty'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Smarty is an interactive learning toy designed to help children learn and have fun!',
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 16),
              Text('Version: 1.0.0'),
              Text('Firmware: 0.9.2'),
              SizedBox(height: 16),
              Text(
                '© 2025 HeySmarty sp. zoo. All rights reserved.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.help_outline, color: Colors.green),
              SizedBox(width: 8),
              Text('Need Help?'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Having trouble with your Smarty toy? Here are some quick tips:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _helpItem(
                '1. Make sure Smarty is charged',
                'The battery should be above 20%',
              ),
              _helpItem(
                '2. Stay within range',
                'Keep your device within 30 feet of Smarty',
              ),
              _helpItem(
                '3. Restart Smarty',
                'Press and hold the power button for 5 seconds',
              ),
              const SizedBox(height: 16),
              const Text(
                'For more help, contact support at:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'office@hey-smarty.com',
                style: TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  Widget _helpItem(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }
}
