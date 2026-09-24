import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/wifi/wifi_config_page.dart';
import 'screens/devices/smarty_connection_page.dart';
import 'screens/user_context_page.dart';
import 'main.dart';
import 'home_tab.dart' show toyStatusLine;
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

  // Repaints the "My Smarty" status line when the toy reports Wi-Fi status.
  StreamSubscription? _wifiStatusSubscription;

  @override
  void initState() {
    super.initState();
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((_) {
      if (mounted) setState(() {});
    });
    _bleManager.registeredListenable.addListener(_onRegisteredChanged);
  }

  void _onRegisteredChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wifiStatusSubscription?.cancel();
    _bleManager.registeredListenable.removeListener(_onRegisteredChanged);
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
                    ],
                  ),
                ),
                ValueListenableBuilder<ToyPhase>(
                  valueListenable: _bleManager.phase,
                  builder: (context, phase, _) => _buildMySmartyCard(phase),
                ),
                SizedBox(height: 16),
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
                // Tear down BLE before signing out so the next account doesn't
                // inherit a live connection: cancels the pending background
                // connect and the link-lost handler before disconnecting.
                await BleManager().disconnectAndReset();
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

  // Permanent "My Smarty" card, rendered from BleManager.phase: one status
  // line, then Wi-Fi / About your child / Forget rows.
  Widget _buildMySmartyCard(ToyPhase phase) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final bool dark = themeProvider.isDarkMode;
    final bool hasToy = phase != ToyPhase.noToy;
    final bool connected = phase == ToyPhase.connected;
    final String? rawName = _bleManager.savedToyName;
    final String? code = hasToy ? BleManager.toyCode(rawName) : null;
    final Color accent = dark ? Color(0xFFFF6EC7) : Colors.blue;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: dark ? Color(0xFF2C2C44) : Colors.blue.shade50,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: dark ? Color(0xFF3A3A5A) : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 30,
                      height: 30,
                      color: accent,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              "My Smarty",
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: dark ? Colors.white : Colors.black87,
                              ),
                            ),
                            if (code != null) ...[
                              SizedBox(width: 8),
                              Text(
                                code,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: dark ? Colors.white54 : Colors.black45,
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: 4),
                        Text(
                          toyStatusLine(_bleManager, short: true),
                          style: TextStyle(
                            fontSize: 14,
                            color: dark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!hasToy)
              _buildMySmartyRow(
                icon: Icons.add_circle_outline,
                label: "Set up Smarty",
                onTap: _openConnectionPage,
              ),
            if (hasToy)
              _buildMySmartyRow(
                icon: Icons.wifi,
                label: "Wi-Fi",
                detail: connected ? _wifiRowDetail() : "Available when Smarty is nearby",
                onTap: connected
                    ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => WifiConfigPage()),
                        ).then((_) {
                          // Refresh state when returning from navigation
                          if (mounted) setState(() {});
                        });
                      }
                    : null,
              ),
            _buildMySmartyRow(
              icon: Icons.chat_bubble,
              label: "About your child",
              detail: "What Smarty should know about your child",
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => UserContextPage()),
                );
              },
            ),
            if (hasToy)
              _buildMySmartyRow(
                icon: Icons.link_off,
                label: "Forget this Smarty",
                destructive: true,
                onTap: _confirmForgetToy,
              ),
          ],
        ),
      ),
    );
  }

  String _wifiRowDetail() {
    final wifi = _bleManager.connectedWifi.trim();
    if (wifi.isEmpty || wifi == "Unknown" || wifi == "NotConnected") {
      return "Checking…";
    }
    if (_bleManager.isWifiConnected) return wifi;
    if (wifi == "Initializing" || wifi == "Reconnecting") return "Joining…";
    return "Not connected";
  }

  Widget _buildMySmartyRow({
    required IconData icon,
    required String label,
    String? detail,
    VoidCallback? onTap,
    bool destructive = false,
  }) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final bool dark = themeProvider.isDarkMode;
    final bool enabled = onTap != null;
    final Color base = destructive
        ? Colors.red.shade400
        : (dark ? Colors.white : Colors.black87);
    final Color fg = enabled ? base : base.withValues(alpha: 0.4);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(width: 8),
            Icon(icon, color: fg, size: 22),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (detail != null) ...[
                    SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 13,
                        color: (dark ? Colors.white70 : Colors.black54)
                            .withValues(alpha: enabled ? 1.0 : 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (enabled && !destructive)
              Icon(
                Icons.arrow_forward_ios,
                color: dark ? Colors.white54 : Colors.black45,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }

  void _openConnectionPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
    ).then((_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_bleManager.watchSavedToy());
    });
  }

  Future<void> _confirmForgetToy() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Forget this Smarty?"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Smarty will be disconnected from this phone. "
                "You can set it up again any time.",
              ),
              if (Platform.isIOS) ...[
                SizedBox(height: 12),
                Text(
                  "To set it up again later, also forget it in "
                  "Settings → Bluetooth.",
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text("Forget"),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
    if (confirmed != true) return;
    await _bleManager.forgetToy();
    if (mounted) setState(() {});
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
                      color: iconColor.withValues(alpha: 0.2),
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
              // TODO: read from package_info_plus instead of hardcoding.
              Text("Version: 1.0.0"),
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
