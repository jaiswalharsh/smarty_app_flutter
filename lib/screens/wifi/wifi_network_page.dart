import 'package:flutter/material.dart';
import '../../services/ble_manager.dart';
import '../../utils/wifi_utils.dart';

class WifiNetworkPage extends StatefulWidget {
  const WifiNetworkPage({super.key});

  @override
  State<WifiNetworkPage> createState() => _WifiNetworkPageState();
}

class _WifiNetworkPageState extends State<WifiNetworkPage> {
  final BleManager _bleManager = BleManager();
  List<String> _wifiNetworks = [];
  bool _isScanningWifi = true;
  String _statusMessage = 'Scanning for WiFi networks...';

  @override
  void initState() {
    super.initState();
    _scanWifiNetworks();
  }

  Future<void> _scanWifiNetworks() async {
    setState(() {
      _isScanningWifi = true;
      _wifiNetworks = [];
      _statusMessage = 'Scanning for WiFi networks...';
    });

    try {
      final networks = await _bleManager.scanWifiNetworks();
      if (!mounted) return;
      setState(() {
        _wifiNetworks = networks.toSet().toList()..sort();
        _isScanningWifi = false;
        _statusMessage = _wifiNetworks.isEmpty
            ? 'No WiFi networks found'
            : 'Found ${_wifiNetworks.length} WiFi networks';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanningWifi = false;
        _statusMessage = 'WiFi scan failed: $e';
      });
    }
  }

  Future<void> _onNetworkSelected(String network) async {
    final password = await WifiUtils.showPasswordDialog(context, network);

    if (password != null && password.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Connecting to $network...';
      });

      final success = await _bleManager.connectToWifi(network, password);

      if (!mounted) return;
      if (success) {
        setState(() {
          _statusMessage = 'Connected to $network!';
        });
        Future.delayed(Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      } else {
        setState(() {
          _statusMessage = 'Failed to connect to $network';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('WiFi Networks'),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: _isScanningWifi ? null : _scanWifiNetworks,
              tooltip: 'Refresh WiFi Networks',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: EdgeInsets.only(bottom: 16),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                      ? Colors.red.withOpacity(0.1)
                      : _statusMessage.contains('Scanning') || _statusMessage.contains('Connecting')
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                        ? Colors.red
                        : _statusMessage.contains('Scanning') || _statusMessage.contains('Connecting')
                            ? Colors.blue
                            : Colors.green,
                  ),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                        ? Colors.red
                        : _statusMessage.contains('Scanning') || _statusMessage.contains('Connecting')
                            ? Colors.blue
                            : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_isScanningWifi)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Scanning for WiFi networks...'),
                      ],
                    ),
                  ),
                )
              else if (_wifiNetworks.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      'No WiFi networks found',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Available WiFi Networks:',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _wifiNetworks.length,
                          itemBuilder: (context, index) {
                            final network = _wifiNetworks[index];
                            return ListTile(
                              leading: Icon(Icons.wifi),
                              title: Text(network),
                              onTap: () => _onNetworkSelected(network),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
