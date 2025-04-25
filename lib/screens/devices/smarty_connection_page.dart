import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../services/ble_manager.dart';
import '../../services/ble_service.dart';
import '../wifi/wifi_config_page.dart';

class SmartyConnectionPage extends StatefulWidget {
  const SmartyConnectionPage({super.key});

  @override
  SmartyConnectionPageState createState() => SmartyConnectionPageState();
}

class SmartyConnectionPageState extends State<SmartyConnectionPage> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  String _connectionResult = '';
  List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  bool _isCheckingConnectedDevices = true;

  // Stream subscriptions
  StreamSubscription? _showSnackBarSubscription;
  StreamSubscription? _deviceConnectionSubscription;

  @override
  void initState() {
    super.initState();
    _checkForConnectedSmartyDevice();

    // Listen for snackbar notifications
    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((message) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
    
    // Listen for device connection state changes
    _subscribeToConnectionChanges();
  }

  @override
  void dispose() {
    _showSnackBarSubscription?.cancel();
    _deviceConnectionSubscription?.cancel();
    super.dispose();
  }
  
  // Subscribe to device connection state changes
  void _subscribeToConnectionChanges() {
    if (_bleManager.connectedDevice != null) {
      // Cancel any existing subscription
      _deviceConnectionSubscription?.cancel();
      
      // Subscribe to connection state changes
      _deviceConnectionSubscription = _bleManager.connectedDevice!.connectionState.listen((state) {
        print("💡 Device connection state changed: $state");
        if (state == BluetoothConnectionState.disconnected) {
          print("❌ Device disconnected");
          setState(() {
            _devices = [];
            _connectionResult = 'Device disconnected';
          });
          
          // Force refresh the UI according to the current state
          _checkForConnectedSmartyDevice();
        }
      });
    }
  }

  // Check if a Smarty device is already connected
  Future<void> _checkForConnectedSmartyDevice() async {
    setState(() {
      _isCheckingConnectedDevices = true;
      _connectionResult = 'Checking for connected devices...';
    });

    try {
      print("🔄 SmartyConnectionPage: Checking for connected devices after possible hot restart");
      
      // First try to restore connection after hot restart
      setState(() {
        _connectionResult = 'Attempting to restore previous connection...';
      });
      
      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();
      
      if (restored) {
        print("✅ SmartyConnectionPage: Successfully restored connection after hot restart");
        setState(() {
          _isCheckingConnectedDevices = false;
          _connectionResult = 'Connected to ${_bleManager.connectedDevice?.platformName ?? "Smarty device"}';
        });
        
        // Show connection success with options
        if (_bleManager.connectedDevice != null) {
          _showConnectionSuccess(_bleManager.connectedDevice!);
        }
        return;
      }
      
      // If restoration fails, continue with normal flow
      // print("🔄 SmartyConnectionPage: Checking connected devices using traditional method");
      // Get already connected devices
      setState(() {
        _connectionResult = 'Checking for connected devices...';
      });
      
      List<BluetoothDevice> connectedDevices = await BleService.getConnectedDevices();
      // print(
      //   "🔍 Checking for connected Smarty devices. Found ${connectedDevices.length} connected devices.",
      // );

      for (BluetoothDevice device in connectedDevices) {
        if (device.platformName.toLowerCase().contains("smarty")) {
          // print(
          //   "✅ Found already connected Smarty device: ${device.platformName}",
          // );

          // Initialize the BLE manager with this device
          setState(() {
            _connectionResult = 'Connecting to ${device.platformName}...';
          });
          
          await _bleManager.initialize(device);
          
          // Subscribe to connection state changes
          _subscribeToConnectionChanges();

          setState(() {
            _isCheckingConnectedDevices = false;
            _connectionResult = 'Connected to ${device.platformName}';
          });
          
          // Show connection success with options instead of auto-navigating
          _showConnectionSuccess(device);
          return;
        }
      }

      // No connected Smarty device found, start scanning
      setState(() {
        _isCheckingConnectedDevices = false;
        _connectionResult = 'No connected devices found'; 
      });
      _startScanning();
    } catch (e) {
      // print("❌ Error checking for connected devices: $e");
      setState(() {
        _isCheckingConnectedDevices = false;
        _connectionResult = 'Error: $e';
      });
      _startScanning();
    }
  }

  Future<void> _startScanning() async {
    setState(() {
      _isScanning = true;
      _devices = []; // Clear existing devices when starting a new scan
      _connectionResult = '';
    });

    try {
      // Listen for scan results
      StreamSubscription<List<ScanResult>>? subscription;
      subscription = BleService.scanForSmartyDevices().listen((results) {
        setState(() {
          // Clear and rebuild the device list from current scan results only
          _devices = [];
          
          // Add only devices from the current scan results
          for (ScanResult result in results) {
            _devices.add(result.device);
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
        _connectionResult = 'Failed to scan: $e';
        _isScanning = false;
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _connectionResult = 'Connecting to ${device.platformName}...';
    });

    try {
      // Set up a timeout for the connection attempt
      bool connectionSuccessful = false;
      
      // Try to connect with a timeout
      await Future.any([
        // Actual connection attempt
        device.connect().then((_) {
          connectionSuccessful = true;
        }),
        // Timeout after 10 seconds
        Future.delayed(Duration(seconds: 10)).then((_) {
          if (!connectionSuccessful) {
            throw TimeoutException('Connection attempt timed out');
          }
        })
      ]);
      
      // If we got here and the connection was successful
      if (connectionSuccessful) {
        // Initialize the BLE manager with this device
        await _bleManager.initialize(device);
        
        // Subscribe to connection state changes for the new device
        _subscribeToConnectionChanges();

        // Show a snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${device.platformName}'),
            backgroundColor: Colors.green,
          ),
        );

        setState(() {
          _connectionResult = 'Connected to ${device.platformName}';
        });
        
        // Get device status
        await Future.delayed(Duration(milliseconds: 500));
        await _bleManager.readStatusUpdate();
        
        // Show connection success with options
        _showConnectionSuccess(device);
      } else {
        throw Exception('Connection failed');
      }
    } catch (e) {
      // print("❌ Error connecting to device: $e");
      setState(() {
        if (e is TimeoutException) {
          _connectionResult = 'Connection timed out. Device may be out of range.';
        } else {
          _connectionResult = 'Failed to connect: $e';
        }
        
        // Refresh the device list after a failed connection attempt
        _startScanning();
      });
    }
  }

  // Show connection success dialog with options
  void _showConnectionSuccess(BluetoothDevice device) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text("Connected to Smarty"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Your Smarty device is now connected via Bluetooth!",
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    _bleManager.isWifiConnected ? Icons.wifi : Icons.wifi_off,
                    color: _bleManager.isWifiConnected ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _bleManager.isWifiConnected 
                          ? "WiFi: Connected to ${_bleManager.connectedWifi}" 
                          : "WiFi: Not connected",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              Text("What would you like to do next?"),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                // Navigate to home page
                Navigator.of(context).pop(); // Return to previous screen
              },
              child: Text("Continue to Home"),
            ),
            ElevatedButton.icon(
              icon: Icon(Icons.wifi),
              label: Text("Set Up WiFi"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                _navigateToWifiConfigPage(); // Navigate to WiFi config
              },
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        );
      },
    );
  }

  // Navigate to WiFi configuration page
  void _navigateToWifiConfigPage() {
    if (_bleManager.isConnected) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WifiConfigPage(),
        ),
      );
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
        appBar: AppBar(
          title: Text(
            'Connect to Smarty',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          elevation: 2,
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
        ),
        body: _isCheckingConnectedDevices
            ? _buildLoadingView()
            : _buildContentView(),
      ),
    );
  }

  // Loading view while checking for connected devices
  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Checking for connected devices...'),
        ],
      ),
    );
  }

  // Main content view
  Widget _buildContentView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Connection status message
          if (_connectionResult.isNotEmpty)
            Container(
              margin: EdgeInsets.only(bottom: 16),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _connectionResult.contains('Failed') || 
                      _connectionResult.contains('Error') ||
                      _connectionResult.contains('timed out')
                    ? Colors.red.withOpacity(0.1)
                    : _connectionResult.contains('Connecting')
                        ? Colors.blue.withOpacity(0.1)
                        : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _connectionResult.contains('Failed') || 
                        _connectionResult.contains('Error') ||
                        _connectionResult.contains('timed out')
                      ? Colors.red
                      : _connectionResult.contains('Connecting')
                          ? Colors.blue
                          : Colors.green,
                ),
              ),
              child: Text(
                _connectionResult,
                style: TextStyle(
                  color: _connectionResult.contains('Failed') || 
                        _connectionResult.contains('Error') ||
                        _connectionResult.contains('timed out')
                      ? Colors.red
                      : _connectionResult.contains('Connecting')
                          ? Colors.blue
                          : Colors.green,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),

          // Scan button
          ElevatedButton.icon(
            icon: Icon(Icons.bluetooth_searching),
            label: Text(_isScanning ? 'Scanning...' : 'Scan for Smarty Devices'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _isScanning ? null : _startScanning,
          ),
          
          SizedBox(height: 16),
          
          // Scanning indicator or device list
          Expanded(
            child: _isScanning
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Scanning for devices...'),
                    ],
                  ),
                )
              : _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bluetooth_disabled,
                            size: 48,
                            color: Colors.grey[400],
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No Smarty devices found',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Make sure your device is powered on and nearby',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          SizedBox(height: 24),
                          ElevatedButton.icon(
                            icon: Icon(Icons.refresh),
                            label: Text('Scan Again'),
                            onPressed: _startScanning,
                          ),
                        ],
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Available Devices:',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.refresh),
                              tooltip: 'Refresh device list',
                              onPressed: _startScanning,
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, index) {
                              final device = _devices[index];
                              return Card(
                                elevation: 2,
                                margin: EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  title: Text(
                                    device.platformName,
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  trailing: Icon(
                                    Icons.bluetooth,
                                    color: Colors.blue,
                                  ),
                                  onTap: () => _connectToDevice(device),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }
} 