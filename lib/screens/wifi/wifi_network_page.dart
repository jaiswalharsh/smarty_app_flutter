import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../services/ble_service.dart';
import '../../utils/wifi_utils.dart';

class WifiNetworkPage extends StatefulWidget {
  final BluetoothService service;
  final BluetoothDevice device;

  const WifiNetworkPage({
    super.key,
    required this.service,
    required this.device,
  });

  @override
  State<WifiNetworkPage> createState() => _WifiNetworkPageState();
}

class _WifiNetworkPageState extends State<WifiNetworkPage> {
  List<String> _wifiNetworks = [];
  bool _isScanningWifi = true;
  String _statusMessage = 'Scanning for WiFi networks...';
  
  // Map to store chunks of WiFi scan data
  final Map<int, String> _wifiScanChunks = {};

  @override
  void initState() {
    super.initState();
    _scanWifiNetworks();
  }

  // Scan for WiFi networks
  Future<void> _scanWifiNetworks() async {
    setState(() {
      _isScanningWifi = true;
      _wifiNetworks = [];
      _statusMessage = 'Scanning for WiFi networks...';
      _wifiScanChunks.clear();
    });

    // Add a delay for any in-progress WiFi operations to complete
    await Future.delayed(Duration(milliseconds: 500));

    try {
      // Find the WiFi scan characteristic
      BluetoothCharacteristic? wifiScanCharacteristic = 
          BleService.findCharacteristic(widget.service, "ab01");

      if (wifiScanCharacteristic != null) {
        // Reset notification state first to ensure clean start
        try {
          await wifiScanCharacteristic.setNotifyValue(false);
          await Future.delayed(Duration(milliseconds: 300));
        } catch (e) {
          print("⚠️ Error resetting notifications: $e");
        }
        
        // Set up notification for the characteristic to receive chunks
        // print("🔄 Setting up notification listener for WiFi scan characteristic");
        
        // Enable notifications
        await wifiScanCharacteristic.setNotifyValue(true);
        // print("✅ Notifications enabled for WiFi scan characteristic");
        
        // Store all received notifications
        List<String> notifications = [];
        bool receivedTotalMarker = false;
        bool receivedEndMarker = false;
        int expectedNetworks = 0;
        int retryCount = 0;
        
        // Listen for notifications using the value stream
        StreamSubscription<List<int>>? subscription;
        
        subscription = wifiScanCharacteristic.lastValueStream.listen((value) {
          if (value.isEmpty) {
            // print("⚠️ Received empty notification data");
            return;
          }
          
          String notification = String.fromCharCodes(value);
          // print("📶 Received notification: $notification");
          
          // Check if this is the TOTAL marker
          if (notification.startsWith("TOTAL:")) {
            try {
              receivedTotalMarker = true;
              expectedNetworks = int.parse(notification.substring(6));
              print("📶 Expecting $expectedNetworks networks");
            } catch (e) {
              print("❌ Error parsing TOTAL marker: $e");
            }
            return;
          }
          
          // Check if this is the END marker
          if (notification == "END") {
            receivedEndMarker = true;
            print("📶 Received END marker, WiFi scan complete");
            
            // Wait a short time to make sure we've received all notifications
            Future.delayed(Duration(milliseconds: 300), () {
              // Process all collected notifications
              if (notifications.isNotEmpty) {
                print("📶 Processing ${notifications.length} network notifications");
                _processWifiScanData(notifications.join('\n'));
              } else if (retryCount < 1) {
                // Try one more time to trigger scan by reading the characteristic
                print("⚠️ Received END marker but no network data, retrying scan...");
                retryCount++;
                
                // Wait a bit and try reading again to trigger results
                Future.delayed(Duration(milliseconds: 500), () async {
                  try {
                    await wifiScanCharacteristic.read();
                    print("📡 Retry read completed");
                  } catch (e) {
                    print("⚠️ Error on retry read: $e");
                    
                    // Show empty networks if retry fails
                    setState(() {
                      _isScanningWifi = false;
                      _statusMessage = 'No WiFi networks found';
                    });
                  }
                });
              } else {
                print("⚠️ Received END marker but no network data after retry");
                setState(() {
                  _isScanningWifi = false;
                  _statusMessage = 'No WiFi networks found';
                });
                
                // Cancel the subscription
                subscription?.cancel();
              }
            });
            return;
          }
          
          // Add this notification to our list
          notifications.add(notification);
          
          // For the new format, a single notification may contain multiple networks separated by newlines
          // if (notification.contains('\n')) {
          //   print("📶 Detected chunked notification with multiple networks");
          //   List<String> chunks = notification.split('\n');
          //   print("📶 Found ${chunks.length} networks in single notification");
          // }
          
          // If we've received all expected networks and the END marker
          if (receivedTotalMarker && receivedEndMarker && 
              expectedNetworks > 0 && notifications.length >= expectedNetworks) {
            print("📶 Received all expected networks and END marker");
            _processWifiScanData(notifications.join('\n'));
            subscription?.cancel();
          }
        });
        
        // Check if the characteristic supports write
        bool supportsWrite = wifiScanCharacteristic.properties.write || 
                           wifiScanCharacteristic.properties.writeWithoutResponse;
        
        if (supportsWrite) {
          // Write to the characteristic to trigger a WiFi scan on the ESP32
          print("📡 Triggering WiFi scan on ESP32...");
          try {
            List<int> triggerValue = utf8.encode("SCAN");
            await wifiScanCharacteristic.write(triggerValue, 
                withoutResponse: wifiScanCharacteristic.properties.writeWithoutResponse);
            // print("📡 Scan trigger sent successfully");
          } catch (e) {
            print("⚠️ Could not write to trigger scan: $e");
            print("⚠️ Falling back to read-only mode");
          }
        } else {
          print("ℹ️ Characteristic doesn't support write, using read-only mode");
        }
        
        // Read the characteristic to start receiving notifications
        try {
          // print("📡 Reading to trigger scan notifications...");
          await wifiScanCharacteristic.read();
          print("📡 Initial read completed");
        } catch (e) {
          print("⚠️ Error reading characteristic: $e");
        }
        
        // Set a timeout to cancel the subscription if we don't receive all chunks
        Future.delayed(Duration(seconds: 15), () {
          if (_isScanningWifi) {
            // print("⏱️ Timeout reached, checking collected notifications");
            subscription?.cancel();
            
            // Process whatever notifications we have if any
            if (notifications.isNotEmpty) {
              print("⏱️ Processing ${notifications.length} notifications after timeout");
              _processWifiScanData(notifications.join('\n'));
            } else {
              // print("⏱️ No networks received after timeout");
              
              // Try one more read before giving up
              try {
                wifiScanCharacteristic.read().then((_) {
                  // print("📡 Final attempt read completed");
                  
                  // Give a short time for notifications to arrive
                  Future.delayed(Duration(milliseconds: 500), () {
                    if (notifications.isEmpty) {
                      setState(() {
                        _isScanningWifi = false;
                        _statusMessage = 'Failed to receive WiFi scan data.';
                      });
                    }
                  });
                });
              } catch (e) {
                print("⚠️ Error on final read attempt: $e");
                setState(() {
                  _isScanningWifi = false;
                  _statusMessage = 'Failed to receive WiFi scan data.';
                });
              }
            }
          }
        });
      } else {
        print("❌ WiFi scan characteristic not found");
        print("Available characteristics:");
        for (BluetoothCharacteristic characteristic in widget.service.characteristics) {
          print("  - ${characteristic.uuid}");
        }
        
        setState(() {
          _statusMessage = 'WiFi scan characteristic not found.';
          _isScanningWifi = false;
        });
      }
    } catch (e) {
      print("❌ Error scanning WiFi: $e");
      setState(() {
        _statusMessage = 'Failed to scan WiFi: $e';
        _isScanningWifi = false;
      });
    }
  }
  
  // Process the WiFi scan data
  void _processWifiScanData(String wifiString) {
    // print("📶 WifiNetworkPage: Processing scan data: $wifiString");
    
    // Pre-process the data to handle chunked format
    // Split by newlines and process each line
    List<String> lines = wifiString.split('\n');
    // print("📶 WifiNetworkPage: Split data into ${lines.length} lines");
    
    // Filter out lines that don't represent networks
    lines = lines.where((line) => 
      line.trim().isNotEmpty && 
      !line.startsWith("TOTAL:") && 
      line != "END"
    ).toList();
    
    // print("📶 WifiNetworkPage: After filtering, ${lines.length} potential network lines");
    
    List<String> networks = WifiUtils.processWifiScanData(lines.join('\n'));
    
    print("📶 WifiNetworkPage: Found ${networks.length} networks");
    
    // Only update UI if we have networks or we need to show empty state
    setState(() {
      _wifiNetworks = networks;
      _isScanningWifi = false;
      
      if (networks.isEmpty) {
        // Try to manually extract network names if processWifiScanData failed
        List<String> manualNetworks = [];
        
        for (String line in lines) {
          if (line.contains(':')) {
            try {
              final parts = line.split(':');
              if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
                manualNetworks.add(parts[1].trim());
              }
            } catch (e) {
              print("📶 Error parsing line manually: $e");
            }
          }
        }
        
        if (manualNetworks.isNotEmpty) {
          print("📶 WifiNetworkPage: Found ${manualNetworks.length} networks with manual parsing");
          _wifiNetworks = manualNetworks.toSet().toList()..sort();
          _statusMessage = 'Found ${_wifiNetworks.length} WiFi networks';
        } else {
          _statusMessage = 'No WiFi networks found';
        }
      } else {
        _statusMessage = 'Found ${_wifiNetworks.length} WiFi networks';
      }
    });
  }

  // Handle WiFi network selection
  Future<void> _onNetworkSelected(String network) async {
    // Show password dialog
    final password = await WifiUtils.showPasswordDialog(context, network);
    
    if (password != null && password.isNotEmpty) {
      // Connect to WiFi
      final success = await WifiUtils.connectToWifi(
        widget.service, 
        network, 
        password, 
        (message) {
          setState(() {
            _statusMessage = message;
          });
        }
      );
      
      if (success) {
        // Return to previous screen after a delay
        Future.delayed(Duration(seconds: 2), () {
          Navigator.pop(context);
        });
      }
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
          title: const Text('WiFi Networks'),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: _scanWifiNetworks,
              tooltip: 'Refresh WiFi Networks',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status message
              Container(
                margin: EdgeInsets.only(bottom: 16),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                      ? Colors.red.withOpacity(0.1)
                      : _statusMessage.contains('Scanning')
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                        ? Colors.red
                        : _statusMessage.contains('Scanning')
                            ? Colors.blue
                            : Colors.green,
                  ),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _statusMessage.contains('Failed') || _statusMessage.contains('Error')
                        ? Colors.red
                        : _statusMessage.contains('Scanning')
                            ? Colors.blue
                            : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              
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
                )
              else if (_wifiNetworks.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      'No WiFi networks found',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
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
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
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
