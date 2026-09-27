import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_info.dart';
import 'screens/account/account_helpers.dart';
import 'screens/account/your_account_page.dart';
import 'services/auth_service.dart';
import 'utils/theme_provider.dart';
import 'widgets/dev_server_label.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

// Smarty's own shortcuts (Wi-Fi, About your child, Forget) live on Home,
// under the toy card; Settings is about the app and the account.
class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: EdgeInsets.only(bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Smarty Settings",
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color:
                              themeProvider.isDarkMode
                                  ? Color(0xFFFF6EC7)
                                  : Colors.blue.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildAccountCard(),
                SizedBox(height: 16),
                _buildSettingsCard(
                  title: "Appearance",
                  description: "Toggle dark mode and customize display",
                  icon:
                      themeProvider.isDarkMode
                          ? Icons.dark_mode
                          : Icons.light_mode,
                  iconColor:
                      themeProvider.isDarkMode
                          ? Color(0xFFFF6EC7)
                          : Colors.amber,
                  bgColor:
                      themeProvider.isDarkMode
                          ? Color(0xFF2C2C44)
                          : Colors.amber.shade50,
                  onTap: () {
                    _showThemeDialog(context, themeProvider);
                  },
                ),
                SizedBox(height: 16),
                _buildSettingsCard(
                  title: "About Smarty",
                  description: "Learn more about your Smarty toy",
                  icon: Icons.smart_toy,
                  iconColor:
                      themeProvider.isDarkMode
                          ?Color(0xFF00FFCC) 
                          : Colors.purple,
                  bgColor:
                      themeProvider.isDarkMode
                          ? Color(0xFF2C2C44)
                          : Colors.purple.shade50,
                  useCustomRobotIcon: true,
                  onTap: () {
                    _showAboutDialog(context);
                  },
                ),
                SizedBox(height: 16),
                _buildSettingsCard(
                  title: "Need Help?",
                  description: "Get help with your Smarty toy",
                  icon: Icons.help_outline,
                  iconColor:
                      themeProvider.isDarkMode
                          ? Color(0xFFFF6EC7)
                          : Colors.green,
                  bgColor:
                      themeProvider.isDarkMode
                          ? Color(0xFF2C2C44)
                          : Colors.green.shade50,
                  onTap: () {
                    _showHelpDialog(context);
                  },
                ),
                const DevServerLabel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Theme dialog
  void _showThemeDialog(BuildContext context, ThemeProvider themeProvider) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                themeProvider.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                color:
                    themeProvider.isDarkMode ? Color(0xFFFF6EC7) : Colors.amber,
              ),
              SizedBox(width: 8),
              Text("Appearance"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Choose your theme mode", style: TextStyle(fontSize: 16)),
              SizedBox(height: 20),
              SwitchListTile(
                title: Text("Dark Mode"),
                subtitle: Text(
                  themeProvider.isDarkMode
                      ? "Fun toy colors!"
                      : "Light mode enabled",
                ),
                secondary: Icon(
                  themeProvider.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                  color:
                      themeProvider.isDarkMode
                          ? Color(0xFFFF6EC7)
                          : Colors.amber,
                ),
                value: themeProvider.isDarkMode,
                onChanged: (_) {
                  themeProvider.toggleTheme();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Close"),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  // "Your account" card: the parent's initials, their name (or "Your
  // account"), and their email. Opens the full account page.
  Widget _buildAccountCard() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final user = AuthService().currentUser;
    final String? name = user?.displayName?.trim();
    final bool hasName = name != null && name.isNotEmpty;
    final String? email = user?.email;
    final Color iconColor =
        themeProvider.isDarkMode ? Color(0xFF00FFCC) : Colors.indigo;

    return _buildSettingsCard(
      title: hasName ? name : "Your account",
      description: (email == null || email.isEmpty) ? "Not signed in" : email,
      icon: Icons.person_outline,
      iconColor: iconColor,
      bgColor:
          themeProvider.isDarkMode ? Color(0xFF2C2C44) : Colors.indigo.shade50,
      leading: AccountInitials(
        initials: initialsFor(displayName: name, email: email),
        color: iconColor,
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => YourAccountPage()),
        ).then((_) {
          // The name may have changed.
          if (mounted) setState(() {});
        });
      },
    );
  }

  // Helper to build nice settings cards
  Widget _buildSettingsCard({
    required String title,
    required String description,
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required VoidCallback onTap,
    bool useCustomRobotIcon = false,
    Widget? leading,
  }) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: bgColor,
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:
                      themeProvider.isDarkMode
                          ? Color(0xFF3A3A5A)
                          : Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: iconColor.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child:
                    leading ??
                    (useCustomRobotIcon
                        ? Image.asset(
                          'assets/images/icon.png',
                          width: 30,
                          height: 30,
                          color: iconColor,
                        )
                        : Icon(icon, color: iconColor, size: 30)),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color:
                            themeProvider.isDarkMode
                                ? Colors.white
                                : Colors.black87,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color:
                            themeProvider.isDarkMode
                                ? Colors.white70
                                : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color:
                    themeProvider.isDarkMode ? Colors.white54 : Colors.black45,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // About dialog
  void _showAboutDialog(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          scrollable: true,
          title: Row(
            children: [
              Image.asset(
                'assets/images/icon.png',
                width: 24,
                height: 24,
                color:
                    themeProvider.isDarkMode
                        ? Color(0xFFFF6EC7)
                        : Colors.purple,
              ),
              SizedBox(width: 8),
              Text("About Smarty"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Smarty is an interactive learning toy designed to help children learn and have fun!",
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 16),
              Text("Version: $appVersion"),
              // Firmware version intentionally not shown: the device doesn't yet
              // report it over BLE, and a hardcoded number would drift and
              // mislead (APP-11). Restore this once it's read from the device.
              SizedBox(height: 16),
              Text(
                "© 2025 HeySmarty sp. zoo. All rights reserved.",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Close"),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  // Help dialog
  void _showHelpDialog(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          scrollable: true,
          title: Row(
            children: [
              Icon(
                Icons.help_outline,
                color:
                    themeProvider.isDarkMode ? Color(0xFF00FFCC) : Colors.green,
              ),
              SizedBox(width: 8),
              Text("Need Help?"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Having trouble with your Smarty toy? Here are some quick tips:",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 16),
              _buildHelpItem(
                "1. Make sure Smarty is charged",
                "If it isn't responding, plug it in to charge for a while",
              ),
              _buildHelpItem(
                "2. Stay within range",
                "Keep your device within 30 feet of Smarty",
              ),
              _buildHelpItem(
                "3. Restart Smarty",
                "Press and hold the power button for 5 seconds",
              ),
              SizedBox(height: 16),
              Text(
                "For more help, contact support at:",
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 8),
              Text(
                "office@hey-smarty.com",
                style: TextStyle(
                  color:
                      themeProvider.isDarkMode
                          ? Color(0xFF00FFCC)
                          : Colors.blue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Close"),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  // Help item
  Widget _buildHelpItem(String title, String subtitle) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: themeProvider.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
          SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color:
                  themeProvider.isDarkMode ? Colors.white70 : Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }
}
