import 'package:flutter/material.dart';

import '../home_tab.dart';
import '../services/ble_manager.dart';
import '../screens/wifi/wifi_config_page.dart';
import '../screens/devices/smarty_connection_page.dart';
import '../widgets/account_menu.dart';

/// Toy tab — the device home. Wraps the existing connection/status view
/// (`HomeTab`) and adds the re-homed device settings (Wi-Fi provisioning /
/// pairing) per the Stitch migration plan §4. Current theme, no reskin.
class ToyTab extends StatelessWidget {
  const ToyTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Toy'),
        actions: [
          IconButton(
            icon: const Icon(Icons.wifi),
            tooltip: 'Wi-Fi & device',
            onPressed: () {
              // Connected → Wi-Fi setup; otherwise route to pairing first.
              if (BleManager().isConnected) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => WifiConfigPage()),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SmartyConnectionPage()),
                );
              }
            },
          ),
          const AccountAvatarAction(),
        ],
      ),
      body: const HomeTab(),
    );
  }
}
