import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/wifi/wifi_config_page.dart';
import 'screens/devices/smarty_connection_page.dart';
import 'screens/user_context_page.dart';
import 'screens/auth/login_page.dart';
import 'main.dart';
import 'services/auth_service.dart';
import 'services/ble_manager.dart';
import 'utils/theme_provider.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  // Stream subscriptions
  StreamSubscription? _deviceConnectionSubscription;
  StreamSubscription? _showSnackBarSubscription;

  @override
  void initState() {
    super.initState();

    // Set up listeners for device status changes
    _setupStatusListeners();
  }

  // Set up status listeners
  void _setupStatusListeners() {
    // Listen for connection state changes only — rebuild when connected/disconnected toggles
    bool lastConnected = _bleManager.isConnected;
    _deviceConnectionSubscription = _bleManager.wifiStatusStream.listen((
      status,
    ) {
      if (!mounted) return;
      final nowConnected = _bleManager.isConnected;
      if (nowConnected != lastConnected) {
        lastConnected = nowConnected;
        setState(() {});
      }
    });

    // Listen for snackbar notifications
    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((
      message,
    ) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    });
  }

  @override
  void dispose() {
    _deviceConnectionSubscription?.cancel();
    _showSnackBarSubscription?.cancel();
    super.dispose();
  }

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
                      SizedBox(height: 8),
                      Text(
                        "Let's set up your toy!",
                        style: TextStyle(
                          fontSize: 16,
                          color:
                              themeProvider.isDarkMode
                                  ? Color(0xFF00FFCC)
                                  : Colors.blue.shade600,
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
                  title: "User Context",
                  description:
                      "Tell Smarty what it should know about your child",
                  icon: Icons.chat_bubble,
                  iconColor:
                      themeProvider.isDarkMode
                          ? Color(0xFF00FFCC)
                          : Colors.pink,
                  bgColor:
                      themeProvider.isDarkMode
                          ? Color(0xFF2C2C44)
                          : Colors.pink.shade50,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => UserContextPage(),
                      ),
                    );
                  },
                ),
                SizedBox(height: 16),
                _bleManager.isConnected
                    ? _buildWifiConfigCard()
                    : _buildConnectDeviceCard(),
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

  // Card for WiFi configuration (when device is connected)
  Widget _buildWifiConfigCard() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    return _buildSettingsCard(
      title: "Configure WiFi",
      description: "Connect your Smarty toy to the internet",
      icon: Icons.wifi,
      iconColor: themeProvider.isDarkMode ? Color(0xFFFF6EC7) : Colors.blue,
      bgColor:
          themeProvider.isDarkMode ? Color(0xFF2C2C44) : Colors.blue.shade50,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => WifiConfigPage()),
        ).then((_) {
          // Refresh state when returning from navigation
          if (mounted) setState(() {});
        });
      },
    );
  }

  // Card showing logged-in account
  Widget _buildAccountCard() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final email = AuthService().currentUser?.email ?? "Not signed in";

    return _buildSettingsCard(
      title: email,
      description: "Manage your account",
      icon: Icons.person_outline,
      iconColor: themeProvider.isDarkMode ? Color(0xFF00FFCC) : Colors.indigo,
      bgColor:
          themeProvider.isDarkMode ? Color(0xFF2C2C44) : Colors.indigo.shade50,
      onTap: () {
        _showAccountDialog();
      },
    );
  }

  // Account dialog with sign-out
  void _showAccountDialog() {
    final email = AuthService().currentUser?.email ?? "Not signed in";
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.person, color: Colors.indigo, size: 24),
              SizedBox(width: 8),
              Text("Account"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(email, style: TextStyle(fontSize: 16)),
              SizedBox(height: 8),
              Text(
                "Signed in",
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Close"),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await AuthService().signOut();
                if (mounted) {
                  Navigator.of(this.context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => SplashScreen()),
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
              child: Text("Sign Out"),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }

  // Card for connecting to device (when no device is connected)
  Widget _buildConnectDeviceCard() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    return _buildSettingsCard(
      title: "Connect to Smarty Device",
      description: "Find and connect to your Smarty toy",
      icon: Icons.bluetooth_searching,
      iconColor: themeProvider.isDarkMode ? Color(0xFFFF6EC7) : Colors.blue,
      bgColor:
          themeProvider.isDarkMode ? Color(0xFF2C2C44) : Colors.blue.shade50,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
        ).then((_) {
          // Refresh state when returning from navigation
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
                      color: iconColor.withOpacity(0.2),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child:
                    useCustomRobotIcon
                        ? Image.asset(
                          'assets/images/icon.png',
                          width: 30,
                          height: 30,
                          color: iconColor,
                        )
                        : Icon(icon, color: iconColor, size: 30),
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
              Text("Version: 1.0.0"),
              Text("Firmware: 0.9.2"),
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
                "The battery should be above 20%",
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
