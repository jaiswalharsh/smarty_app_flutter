import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  // User data form controllers
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _hobbyController = TextEditingController();

  // Status information
  String _connectedWifi = "Unknown";
  String _batteryLevel = "Unknown";
  String _wifiStatusMessage = "";

  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  // Stream subscriptions
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription? _batteryStatusSubscription;
  StreamSubscription? _wifiStatusMessageSubscription;
  StreamSubscription? _showSnackBarSubscription;

  @override
  void initState() {
    super.initState();
    _checkForConnectedDevices();

    // Listen for status updates
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      setState(() {
        _connectedWifi = wifiName;
      });
    });

    _batteryStatusSubscription = _bleManager.batteryStatusStream.listen((
      batteryLevel,
    ) {
      setState(() {
        _batteryLevel = batteryLevel;
      });
    });

    // Listen for WiFi status message updates
    _wifiStatusMessageSubscription = _bleManager.wifiStatusMessageStream.listen(
      (message) {
        setState(() {
          _wifiStatusMessage = message;
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
    _nameController.dispose();
    _ageController.dispose();
    _hobbyController.dispose();
    _wifiStatusSubscription?.cancel();
    _batteryStatusSubscription?.cancel();
    _wifiStatusMessageSubscription?.cancel();
    _showSnackBarSubscription?.cancel();
    super.dispose();
  }

  // Check if we already have a connected device
  Future<void> _checkForConnectedDevices() async {
    try {
      // Get connected devices using the BleService
      List<BluetoothDevice> connectedDevices = BleService.getConnectedDevices();
      
      if (connectedDevices.isNotEmpty) {
        // Find the first device with "Smarty" in the name
        for (BluetoothDevice device in connectedDevices) {
          if (device.platformName.toLowerCase().contains("smarty")) {
            print("✅ HomeTab: Found already connected Smarty device: ${device.platformName}");
            
            // Initialize the BLE manager with this device
            await _bleManager.initialize(device);
            
            // Update the UI with current values
            setState(() {
              _connectedWifi = _bleManager.connectedWifi;
              _batteryLevel = _bleManager.batteryLevel;
            });
            
            // Read the status update to ensure we have the latest values
            await Future.delayed(Duration(milliseconds: 500));
            await _bleManager.readStatusUpdate();
            
            break;
          }
        }
      } else {
        print("ℹ️ HomeTab: No connected devices found");
      }
    } catch (e) {
      print("❌ HomeTab: Error checking for connected devices: $e");
    }
  }

  // Send user data to the device
  Future<void> _sendUserData() async {
    if (!_bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not connected to a Smarty device')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      bool success = await _bleManager.sendUserData(
        _nameController.text,
        _ageController.text,
        _hobbyController.text,
      );

      if (success) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('User data sent successfully')));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send user data')));
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error sending user data: $e')));
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
        // Add safe area to avoid the notch
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child:
                _bleManager.isConnected
                    ? _buildConnectedView()
                    : _buildDisconnectedView(),
          ),
        ),
      ),
    );
  }

  Widget _buildDisconnectedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Not connected to Smarty',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'Go to Settings tab to connect to your Smarty device',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Device info card
          Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bluetooth_connected, color: Colors.blue),
                      SizedBox(width: 8),
                      Text(
                        'Connected to Smarty',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.wifi,
                        color:
                            _bleManager.isWifiConnected
                                ? Colors.green
                                : Colors.orange,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'WiFi: ${_bleManager.isWifiConnected ? _connectedWifi : "Not connected"}',
                            ),
                            if (_wifiStatusMessage.isNotEmpty)
                              Text(
                                _wifiStatusMessage,
                                style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      _wifiStatusMessage.contains('Failed') ||
                                              _wifiStatusMessage.contains(
                                                'failed',
                                              )
                                          ? Colors.red
                                          : Colors.grey[600],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.battery_full, color: Colors.amber),
                      SizedBox(width: 8),
                      Text('Battery: $_batteryLevel%'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          SizedBox(height: 24),

          // User data form
          Text(
            'User Information',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 16),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a name';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 16),
                TextFormField(
                  controller: _ageController,
                  decoration: InputDecoration(
                    labelText: 'Age',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter an age';
                    }
                    if (int.tryParse(value) == null) {
                      return 'Please enter a valid number';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 16),
                TextFormField(
                  controller: _hobbyController,
                  decoration: InputDecoration(
                    labelText: 'Hobby',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.sports_soccer),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a hobby';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _sendUserData,
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                    minimumSize: Size(double.infinity, 50),
                  ),
                  child: Text('Send to Smarty', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
