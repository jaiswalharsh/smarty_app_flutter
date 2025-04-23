import 'package:flutter/material.dart';
import 'screens/wifi/wifi_config_page.dart';
import 'services/ble_service.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          ListTile(
            title: Text('Accounts'),
            onTap: () {
              // TODO: Navigate to Accounts page
            },
          ),
          ListTile(
            title: Text('Wifi Config'),
            onTap: () {
              // Navigate to Wifi Config page with new BLE implementation
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => WifiConfigPage()),
              );
            },
          ),
          ListTile(
            title: Text('Logout'),
            onTap: () {
              // TODO: Implement Logout functionality
            },
          ),
        ],
      ),
    );
  }
}
