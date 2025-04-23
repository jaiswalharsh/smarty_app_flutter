import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../services/ble_manager.dart';
import '../../services/ble_service.dart';
import 'wifi_network_page.dart';

class WifiConfigPage extends StatefulWidget {
  const WifiConfigPage({super.key});

  @override
  WifiConfigPageState createState() => WifiConfigPageState();
}

class WifiConfigPageState extends State<WifiConfigPage> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  String _provisioningResult = '';
  List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  bool _isScanningWifi = false;

  // Current WiFi information
  String _currentWifiName = "Unknown";
  String _wifiStatusMessage = "";
  bool _isCheckingConnectedDevices = true;

  // Stream subscriptions
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription? _wifiStatusMessageSubscription;
  StreamSubscription? _showSnackBarSubscription;

  @override
  void initState() {
    super.initState();
    _checkForConnectedSmartyDevice();

    // Listen for WiFi status updates
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      setState(() {
        _currentWifiName = wifiName;
      });
    });

    // Listen for WiFi status message updates
    _wifiStatusMessageSubscription = _bleManager.wifiStatusMessageStream.listen(
      (message) {
        setState(() {
          _wifiStatusMessage = message;
          _provisioningResult = message;
        });
      },
    );

    // Listen for snackbar notifications
    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((
      message,
    ) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    _wifiStatusSubscription?.cancel();
    _wifiStatusMessageSubscription?.cancel();
    _showSnackBarSubscription?.cancel();
    super.dispose();
  }

  // Check if a Smarty device is already connected
  Future<void> _checkForConnectedSmartyDevice() async {
    setState(() {
      _isCheckingConnectedDevices = true;
    });

    try {
      // Get already connected devices
      List<BluetoothDevice> connectedDevices = BleService.getConnectedDevices();
      print(
        "🔍 Checking for connected Smarty devices. Found ${connectedDevices.length} connected devices.",
      );

      for (BluetoothDevice device in connectedDevices) {
        if (device.platformName.toLowerCase().contains("smarty")) {
          print(
            "✅ Found already connected Smarty device: ${device.platformName}",
          );

          // Initialize the BLE manager with this device
          await _bleManager.initialize(device);

          setState(() {
            _isCheckingConnectedDevices = false;
            _currentWifiName = _bleManager.connectedWifi;
            _provisioningResult = 'Connected to ${device.platformName}';
            if (_currentWifiName != "Unknown") {
              _provisioningResult = 'Connected to WiFi: $_currentWifiName';
            }
          });
          return;
        }
      }

      // No connected Smarty device found, start scanning
      setState(() {
        _isCheckingConnectedDevices = false;
      });
      _startScanning();
    } catch (e) {
      print("❌ Error checking for connected devices: $e");
      setState(() {
        _isCheckingConnectedDevices = false;
      });
      _startScanning();
    }
  }

  Future<void> _startScanning() async {
    setState(() {
      _isScanning = true;
      _devices = [];
      _provisioningResult = '';
    });

    try {
      // Listen for scan results
      StreamSubscription<List<ScanResult>>? subscription;
      subscription = BleService.scanForSmartyDevices().listen((results) {
        setState(() {
          // Add new devices to the list
          for (ScanResult result in results) {
            if (!_devices.contains(result.device)) {
              print("🔍 Found Smarty device: ${result.device.platformName}");
              _devices.add(result.device);
            }
          }
        });
      });

      // Stop scanning after 4 seconds
      await Future.delayed(Duration(seconds: 4));
      await BleService.stopScan();
      subscription.cancel();

      setState(() {
        _isScanning = false;
      });
    } catch (e) {
      setState(() {
        _provisioningResult = 'Failed to scan: $e';
        _isScanning = false;
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _provisioningResult = 'Connecting to ${device.platformName}...';
    });

    try {
      await device.connect();

      // Initialize the BLE manager with this device
      await _bleManager.initialize(device);

      setState(() {
        _provisioningResult = 'Connected to ${device.platformName}';
        _currentWifiName = _bleManager.connectedWifi;
        if (_currentWifiName != "Unknown") {
          _provisioningResult = 'Connected to WiFi: $_currentWifiName';
        }
      });
    } catch (e) {
      setState(() {
        _provisioningResult = 'Failed to connect: $e';
      });
    }
  }

  // Navigate to WiFi network page
  Future<void> _navigateToWifiNetworkPage() async {
    if (_bleManager.isConnected && _bleManager.smartyService != null) {
      // Navigate to WiFi configuration page
      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => WifiNetworkPage(
                service: _bleManager.smartyService!,
                device: _bleManager.connectedDevice!,
              ),
        ),
      );
    } else {
      setState(() {
        _provisioningResult = 'Smarty service not found.';
      });
    }
  }

  // Reset WiFi connection
  Future<void> _resetWifiConnection() async {
    setState(() {
      _provisioningResult = 'Resetting WiFi connection...';
    });

    bool success = await _bleManager.resetWifiConnection();

    if (success) {
      setState(() {
        _provisioningResult = 'Successfully reset WiFi connection';
      });
    } else {
      setState(() {
        _provisioningResult = 'Failed to reset WiFi connection';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Dismiss keyboard when tapping outside of text fields
      onTap: () {
        FocusScope.of(context).unfocus();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('WiFi Configuration')),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Show current WiFi info if connected to Smarty
              if (_bleManager.isConnected)
                Card(
                  elevation: 4,
                  margin: EdgeInsets.only(bottom: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.wifi, color: Colors.green),
                            SizedBox(width: 8),
                            Text(
                              'Currently Connected to:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Text(
                          _bleManager.isWifiConnected
                              ? _currentWifiName
                              : "Not connected",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: Icon(Icons.refresh),
                          label: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: Text('Reset WiFi'),
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: _resetWifiConnection,
                        ),
                      ],
                    ),
                  ),
                ),

              // Step 1: Scan for Bluetooth devices (only show if not connected)
              if (!_bleManager.isConnected)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _isScanning ? null : _startScanning,
                  child: Text(
                    _isScanning ? 'Scanning...' : 'Scan for Smarty Devices',
                  ),
                ),

              if (!_bleManager.isConnected) const SizedBox(height: 16),

              // Scanning indicator
              if (_isScanning)
                Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      const SizedBox(height: 8),
                      const Text('Scanning for devices...'),
                    ],
                  ),
                ),

              // Step 2: Show device list with connect on tap
              if (!_isScanning &&
                  _devices.isNotEmpty &&
                  !_bleManager.isConnected)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Available Devices:',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (context, index) {
                            final device = _devices[index];
                            return ListTile(
                              title: Text(device.platformName),
                              trailing: const Icon(
                                Icons.bluetooth,
                                color: Colors.blue,
                              ),
                              onTap: () => _connectToDevice(device),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

              // Step 3: Show WiFi scanning indicator
              if (_bleManager.isConnected && _isScanningWifi)
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
                ),

              // Step 4: Show WiFi networks button if connected but no WiFi is configured yet
              if (_bleManager.isConnected &&
                  !_isScanningWifi &&
                  !_bleManager.isWifiConnected)
                ElevatedButton.icon(
                  icon: Icon(Icons.wifi),
                  label: Text('Configure WiFi Networks'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _navigateToWifiNetworkPage,
                ),

              // Result message
              if (_provisioningResult.isNotEmpty)
                Container(
                  margin: EdgeInsets.only(top: 16),
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        _provisioningResult.contains('Failed') ||
                                _provisioningResult.contains('Error') ||
                                _provisioningResult.contains('Please select')
                            ? Colors.red.withOpacity(0.1)
                            : _provisioningResult.contains('Connecting') ||
                                _provisioningResult.contains('Scanning')
                            ? Colors.blue.withOpacity(0.1)
                            : Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          _provisioningResult.contains('Failed') ||
                                  _provisioningResult.contains('Error') ||
                                  _provisioningResult.contains('Please select')
                              ? Colors.red
                              : _provisioningResult.contains('Connecting') ||
                                  _provisioningResult.contains('Scanning')
                              ? Colors.blue
                              : Colors.green,
                    ),
                  ),
                  child: Text(
                    _provisioningResult,
                    style: TextStyle(
                      color:
                          _provisioningResult.contains('Failed') ||
                                  _provisioningResult.contains('Error') ||
                                  _provisioningResult.contains('Please select')
                              ? Colors.red
                              : _provisioningResult.contains('Connecting') ||
                                  _provisioningResult.contains('Scanning')
                              ? Colors.blue
                              : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
