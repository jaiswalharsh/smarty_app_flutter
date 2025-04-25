import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../services/ble_manager.dart';
import 'wifi_network_page.dart';

class WifiConfigPage extends StatefulWidget {
  const WifiConfigPage({super.key});

  @override
  WifiConfigPageState createState() => WifiConfigPageState();
}

class WifiConfigPageState extends State<WifiConfigPage> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  final bool _isScanningWifi = false;

  // Current WiFi information
  String _currentWifiName = "Unknown";
  bool _isLoading = true;

  // Stream subscriptions
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription? _wifiStatusMessageSubscription;
  StreamSubscription? _showSnackBarSubscription;
  StreamSubscription? _deviceConnectionSubscription;

  @override
  void initState() {
    super.initState();
    _initializeWifiConfig();

    // Listen for WiFi status updates
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      setState(() {
        _currentWifiName = wifiName;
        
        // If the device is disconnected, navigate back to connection page
        if (wifiName == "NotConnected") {
          print("📱 WifiConfigPage: Detected device disconnection");
          _navigateToDeviceConnectionPage();
        }
      });
    });

    // Listen for snackbar notifications
    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((
      message,
    ) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
    
    // Listen for device connection state changes
    _subscribeToConnectionChanges();
  }

  @override
  void dispose() {
    _wifiStatusSubscription?.cancel();
    _wifiStatusMessageSubscription?.cancel();
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
          
          // Navigate back to device connection page on disconnect
          _navigateToDeviceConnectionPage();
        }
      });
    } else {
      // No device connected, go back to connection page
      _navigateToDeviceConnectionPage();
    }
  }

  // Initialize WiFi configuration page
  Future<void> _initializeWifiConfig() async {
    setState(() {
      _isLoading = true;
    });

    // Ensure we have a connected device
    if (_bleManager.connectedDevice == null) {
      // No connected device, navigate back to connection page
      _navigateToDeviceConnectionPage();
      return;
    }

    // Request a status update to get the latest WiFi information
    try {
      await _bleManager.readStatusUpdate();
      
      // Short delay to allow status to update
      await Future.delayed(Duration(milliseconds: 1000));
    } catch (e) {
      print("Error getting status update: $e");
    }

    setState(() {
      _isLoading = false;
      _currentWifiName = _bleManager.connectedWifi;
    });
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
        _currentWifiName = 'Smarty service not found.';
      });
      
      // Navigate back to device connection page
      _navigateToDeviceConnectionPage();
    }
  }

  // Navigate to device connection page
  void _navigateToDeviceConnectionPage() {
    // Only navigate back if we're not already popping
    if (Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }
  }

  // Reset WiFi connection
  Future<void> _resetWifiConnection() async {
    bool success = await _bleManager.resetWifiConnection();

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully forgot WiFi network'))
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to forget WiFi network'))
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      // Handle back button press
      onWillPop: () async {
        // Simply allow the pop to happen naturally
        return true;
      },
      child: GestureDetector(
        // Dismiss keyboard when tapping outside of text fields
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              'WiFi Configuration',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            elevation: 2,
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: _isLoading
              ? _buildLoadingView()
              : _buildContentView(),
        ),
      ),
    );
  }

  // Loading view
  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading WiFi configuration...'),
        ],
      ),
    );
  }

  // Main content view based on WiFi connection state
  Widget _buildContentView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Content based on WiFi connection state
          if (!_bleManager.isWifiConnected) 
            _buildWifiNotConnectedView()
          else
            _buildWifiConnectedView(),
        ],
      ),
    );
  }

  // View when not connected to WiFi
  Widget _buildWifiNotConnectedView() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status card
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
                      Icon(Icons.wifi_off, color: Colors.orange),
                      SizedBox(width: 8),
                      Text(
                        'WiFi Not Connected',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Your Smarty device needs WiFi to connect to the internet.',
                    style: TextStyle(
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Configure WiFi button
          ElevatedButton.icon(
            icon: Icon(Icons.wifi),
            label: Text('Set Up WiFi Network'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _navigateToWifiNetworkPage,
          ),
          
          SizedBox(height: 16),
          
          // WiFi scanning indicator
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
            ),
            
          // Space at the bottom for future elements
          Spacer(),
        ],
      ),
    );
  }

  // View when connected to WiFi
  Widget _buildWifiConnectedView() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // WiFi status card
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
                      Expanded(
                        child: Text(
                          'Connected to WiFi',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    _currentWifiName == "NoCredentials" || _currentWifiName.isEmpty 
                    ? 'Connected'
                    : 'Network: $_currentWifiName',
                    style: TextStyle(
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Buttons
          ElevatedButton.icon(
            icon: Icon(Icons.refresh),
            label: Text('Change WiFi Network'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _navigateToWifiNetworkPage,
          ),
          
          SizedBox(height: 12),
          
          OutlinedButton.icon(
            icon: Icon(Icons.power_off),
            label: Text('Forget WiFi Network'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _resetWifiConnection,
          ),
          
          // Space at the bottom for future elements
          Spacer(),
        ],
      ),
    );
  }
}

