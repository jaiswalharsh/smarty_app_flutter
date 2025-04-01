import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Import MethodChannel and PlatformException

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
              // Navigate to Wifi Config page with ESP Provision functionality
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

class WifiConfigPage extends StatefulWidget {
  const WifiConfigPage({super.key});

  @override
  State<WifiConfigPage> createState() => _WifiConfigPageState();
}

class _WifiConfigPageState extends State<WifiConfigPage> {
  final _wifiPasswordController = TextEditingController();
  String _provisioningResult = '';
  List<String> _devices = [];
  String _connectingDevice = ''; // Track which device is currently connecting
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isScanningWifi = false;
  List<String> _wifiNetworks = [];
  String _selectedWifiNetwork = '';
  
  final _methodChannel = MethodChannel('esp_provisioning_channel');

  int _scanErrorCount = 0;
  int _wifiScanRetryCount = 0;
  final int _maxWifiScanRetries = 3;

  Future<void> _startScanning() async {
    setState(() {
      _isScanning = true;
      _devices = [];
      _connectingDevice = '';
      _isConnected = false;
      _wifiNetworks = [];
      _selectedWifiNetwork = '';
      _provisioningResult = '';
    });
    
    try {
      final List<dynamic> result = await _methodChannel.invokeMethod('startScanning');
      setState(() {
        _devices = result.map((item) => item.toString()).toList();
        _isScanning = false;
      });
    } on PlatformException catch (e) { 
      setState(() {
        _scanErrorCount++;
        // _provisioningResult = 'Failed to scan: ${e.message}';
        if (e.code == 'SCAN_ERROR') {
          _provisioningResult = 'No Smarty devices found';
        } else {
          _provisioningResult = 'Error: ${e.message}';
        }
        if (_scanErrorCount >= 3) {
          _provisioningResult += "\nTip: Please try restarting your Smarty device.";
        }
        debugPrint('Error: ${e.message}');
        debugPrint('Error code: ${e.code}');
        debugPrint('Error details: ${e.details}');
        _isScanning = false;
      });
    }
  }
  
  Future<void> _connectToDevice(String deviceName) async {
    if (deviceName.isEmpty) return;
    
    debugPrint('🔵 Attempting to connect to device: $deviceName');
    
    setState(() {
      _connectingDevice = deviceName;
      _provisioningResult = 'Connecting to $deviceName...';
    });
    
    try {
      // Add a small delay before connecting to ensure UI updates
      await Future.delayed(Duration(milliseconds: 500));
      
      debugPrint('🔵 Calling native connectToDevice method');
      final result = await _methodChannel.invokeMethod('connectToDevice', {
        'deviceName': deviceName,
      });
      
      debugPrint('🔵 Native connectToDevice returned: $result');
      
      final bool isConnected = result == "CONNECTED";
      debugPrint(isConnected ? '✅ Connection successful' : '❌ Connection failed');
      
      setState(() {
        _isConnected = isConnected;
        
        if (_isConnected) {
          _provisioningResult = 'Connected to $deviceName';
          _connectingDevice = '';
          
          // Add a longer delay before scanning WiFi to ensure connection is stable
          Future.delayed(Duration(seconds: 2), () {
            debugPrint('🔵 Starting WiFi scan after successful connection');
            _scanWifiNetworks();
          });
        } else {
          _provisioningResult = 'Failed to connect to $deviceName';
          _connectingDevice = '';
        }
      });
    } on PlatformException catch (e) {
      debugPrint('❌ PlatformException during connection: ${e.message}');
      debugPrint('❌ Error code: ${e.code}');
      debugPrint('❌ Error details: ${e.details}');
      
      String errorMessage = 'Failed to connect';
      
      // Handle specific error codes
      if (e.code == 'CONNECTION_TIMEOUT') {
        errorMessage = 'Connection timed out. Please try again.';
      } else if (e.code == 'CONNECTION_FAILED') {
        errorMessage = 'Failed to connect to device. Please try again.';
      } else if (e.code == 'DEVICE_DISCONNECTED') {
        errorMessage = 'Device disconnected. Please try again.';
      } else if (e.code == 'UNKNOWN_STATUS') {
        errorMessage = 'Unknown connection status. Please try again.';
      } else if (e.message != null) {
        errorMessage = 'Failed to connect: ${e.message}';
      }
      
      setState(() {
        _provisioningResult = errorMessage;
        _connectingDevice = ''; // Clear connecting status on error
      });
    } catch (e) {
      debugPrint('❌ Unexpected error during connection: $e');
      
      setState(() {
        _provisioningResult = 'Unexpected error: $e';
        _connectingDevice = '';
      });
    }
  }
  
  Future<void> _scanWifiNetworks() async {
    debugPrint('🔵 Starting WiFi network scan');
    
    setState(() {
      _isScanningWifi = true;
      _wifiNetworks = [];
      _selectedWifiNetwork = '';
      _provisioningResult = 'Scanning for WiFi networks...';
    });
    
    try {
      debugPrint('🔵 Calling native scanWifiNetworks method');
      final List<dynamic> result = await _methodChannel.invokeMethod('scanWifiNetworks');
      debugPrint('✅ WiFi scan successful, found ${result.length} networks');
      
      // Reset retry count on success
      _wifiScanRetryCount = 0;
      
      if (result.isEmpty) {
        setState(() {
          _provisioningResult = 'No WiFi networks found. Please try again.';
          _isScanningWifi = false;
        });
        return;
      }
      
      setState(() {
        _wifiNetworks = result.map((item) => item.toString()).toList();
        _isScanningWifi = false;
        _provisioningResult = 'Found ${_wifiNetworks.length} WiFi networks';
      });
    } on PlatformException catch (e) {
      debugPrint('❌ PlatformException during WiFi scan: ${e.message}');
      debugPrint('❌ Error code: ${e.code}');
      debugPrint('❌ Error details: ${e.details}');
      
      String errorMessage = 'Failed to scan WiFi';
      
      // Handle specific error codes
      if (e.code == 'WIFI_SCAN_TIMEOUT') {
        errorMessage = 'WiFi scan timed out. Please try again.';
      } else if (e.code == 'WIFI_SCAN_ERROR') {
        errorMessage = 'Error scanning WiFi: ${e.message}';
        
        // Increment retry count
        _wifiScanRetryCount++;
        
        // Auto-retry if we haven't exceeded the maximum retries
        if (_wifiScanRetryCount < _maxWifiScanRetries) {
          setState(() {
            _provisioningResult = 'WiFi scan failed. Retrying... (${_wifiScanRetryCount}/$_maxWifiScanRetries)';
            _isScanningWifi = false;
          });
          
          // Wait a bit longer before retrying
          Future.delayed(Duration(seconds: 3), () {
            _scanWifiNetworks();
          });
          return;
        }
      } else if (e.message != null) {
        errorMessage = 'Failed to scan WiFi: ${e.message}';
      }
      
      setState(() {
        _provisioningResult = errorMessage;
        _isScanningWifi = false;
      });
      
      // Add a retry button after a failed scan
      _showRetryDialog();
    } catch (e) {
      debugPrint('❌ Unexpected error during WiFi scan: $e');
      
      setState(() {
        _provisioningResult = 'Unexpected error during WiFi scan: $e';
        _isScanningWifi = false;
      });
      
      // Add a retry button after a failed scan
      _showRetryDialog();
    }
  }
  
  void _showRetryDialog() {
    // Only show the dialog if we're still on this screen
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('WiFi Scan Failed'),
        content: Text('Would you like to try scanning for WiFi networks again?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Reset retry count when manually retrying
              _wifiScanRetryCount = 0;
              _scanWifiNetworks();
            },
            child: Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectAndProvision() async {
    if (_selectedWifiNetwork.isEmpty || _wifiPasswordController.text.isEmpty) {
      setState(() {
        _provisioningResult = 'Please select a WiFi network and enter password';
      });
      return;
    }
    
    setState(() {
      _provisioningResult = 'Provisioning...';
    });
    
    try {
      final result = await _methodChannel.invokeMethod('connectAndProvision', {
        'ssid': _selectedWifiNetwork,
        'password': _wifiPasswordController.text,
      });
      setState(() {
        _provisioningResult = result == "SUCCESS" 
            ? 'Successfully connected to WiFi!' 
            : 'Failed to connect to WiFi';
      });
    } on PlatformException catch (e) { 
      debugPrint('❌ PlatformException during provisioning: ${e.message}');
      debugPrint('❌ Error code: ${e.code}');
      debugPrint('❌ Error details: ${e.details}');
      
      String errorMessage = 'Failed to provision';
      
      // Handle specific error codes
      if (e.code == 'PROVISION_TIMEOUT') {
        errorMessage = 'Provisioning timed out. Please try again.';
      } else if (e.code == 'PROVISION_ERROR') {
        errorMessage = 'Provisioning failed. Please try again.';
      } else if (e.message != null) {
        errorMessage = 'Failed to provision: ${e.message}';
      }
      
      setState(() {
        _provisioningResult = errorMessage;
      });
    } catch (e) {
      debugPrint('❌ Unexpected error during provisioning: $e');
      
      setState(() {
        _provisioningResult = 'Unexpected error during provisioning: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('WiFi Configuration')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Step 1: Scan for Bluetooth devices
            if (!_isConnected)
              ElevatedButton(
                onPressed: _isScanning ? null : _startScanning,
                child: Text(_isScanning ? 'Scanning...' : 'Scan for Smarty Devices'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            
            SizedBox(height: 16),
            
            // Scanning indicator
            if (_isScanning)
              Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text('Scanning for devices...'),
                  ],
                ),
              ),
              
            // Step 2: Show device list with connect on tap
            if (!_isScanning && _devices.isNotEmpty && !_isConnected)
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
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (context, index) {
                            final device = _devices[index];
                            final isConnecting = device == _connectingDevice;
                            
                            return ListTile(
                              title: Text(device),
                              tileColor: isConnecting ? Colors.blue.withOpacity(0.1) : null,
                              trailing: isConnecting 
                                ? SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(Icons.bluetooth, color: Colors.blue),
                              onTap: isConnecting ? null : () => _connectToDevice(device),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            
            // Step 3: Show WiFi scanning indicator
            if (_isConnected && _isScanningWifi)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Scanning for WiFi networks...'),
                    ],
                  ),
                ),
              ),
            
            // Step 4: Show WiFi networks
            if (_isConnected && !_isScanningWifi && _wifiNetworks.isNotEmpty)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Available WiFi Networks:',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.refresh),
                          onPressed: _scanWifiNetworks,
                          tooltip: 'Refresh WiFi Networks',
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          itemCount: _wifiNetworks.length,
                          itemBuilder: (context, index) {
                            final network = _wifiNetworks[index];
                            final isSelected = network == _selectedWifiNetwork;
                            
                            return ListTile(
                              leading: Icon(Icons.wifi),
                              title: Text(network),
                              tileColor: isSelected ? Colors.blue.withOpacity(0.1) : null,
                              trailing: isSelected ? Icon(Icons.check, color: Colors.blue) : null,
                              onTap: () {
                                setState(() {
                                  _selectedWifiNetwork = network;
                                  // Clear previous password when selecting a new network
                                  _wifiPasswordController.clear();
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    
                    // Step 5: Show password field for selected WiFi
                    if (_selectedWifiNetwork.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Enter Password for "$_selectedWifiNetwork":',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            TextField(
                              controller: _wifiPasswordController,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: 'WiFi Password',
                                border: OutlineInputBorder(),
                                filled: true,
                                fillColor: Colors.white,
                                suffixIcon: IconButton(
                                  icon: Icon(Icons.send),
                                  onPressed: _connectAndProvision,
                                  tooltip: 'Connect',
                                ),
                              ),
                              onSubmitted: (_) => _connectAndProvision(),
                            ),
                            SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _connectAndProvision,
                              child: Text('Connect to WiFi'),
                              style: ElevatedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            
            // Result message
            if (_provisioningResult.isNotEmpty)
              Container(
                margin: EdgeInsets.only(top: 16),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _provisioningResult.contains('Failed') || 
                         _provisioningResult.contains('Error') ||
                         _provisioningResult.contains('Please select')
                      ? Colors.red.withOpacity(0.1) 
                      : _provisioningResult.contains('Provisioning...') ||
                        _provisioningResult.contains('Connecting') ||
                        _provisioningResult.contains('Scanning') ||
                        _provisioningResult.contains('Retrying')
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _provisioningResult.contains('Failed') || 
                           _provisioningResult.contains('Error') ||
                           _provisioningResult.contains('Please select')
                        ? Colors.red 
                        : _provisioningResult.contains('Provisioning...') ||
                          _provisioningResult.contains('Connecting') ||
                          _provisioningResult.contains('Scanning') ||
                          _provisioningResult.contains('Retrying')
                            ? Colors.blue
                            : Colors.green,
                  ),
                ),
                child: Text(
                  _provisioningResult,
                  style: TextStyle(
                    color: _provisioningResult.contains('Failed') || 
                           _provisioningResult.contains('Error') ||
                           _provisioningResult.contains('Please select')
                        ? Colors.red 
                        : _provisioningResult.contains('Provisioning...') ||
                          _provisioningResult.contains('Connecting') ||
                          _provisioningResult.contains('Scanning') ||
                          _provisioningResult.contains('Retrying')
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
    );
  }
}
