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
  int _totalWifiScanChunks = 0;

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
      _totalWifiScanChunks = 0;
    });

    try {
      // Find the WiFi scan characteristic
      BluetoothCharacteristic? wifiScanCharacteristic = 
          BleService.findCharacteristic(widget.service, "ab01");

      if (wifiScanCharacteristic != null) {
        // Set up notification for the characteristic to receive chunks
        print("🔄 Setting up notification listener for WiFi scan characteristic");
        
        // Enable notifications
        await wifiScanCharacteristic.setNotifyValue(true);
        print("✅ Notifications enabled for WiFi scan characteristic");
        
        // Listen for notifications using the value stream
        StreamSubscription<List<int>>? subscription;
        
        subscription = wifiScanCharacteristic.lastValueStream.listen((value) {
          if (value.isEmpty) {
            print("⚠️ Received empty notification data");
            return;
          }
          
          String chunkData = String.fromCharCodes(value);
          print("📶 Received chunk data (${value.length} bytes): $chunkData");
          
          // Parse the chunk format: [chunk_index]/[total_chunks]:[data]
          if (chunkData.contains('/') && chunkData.contains(':')) {
            int separatorIndex = chunkData.indexOf(':');
            String header = chunkData.substring(0, separatorIndex);
            String data = chunkData.substring(separatorIndex + 1);
            
            List<String> headerParts = header.split('/');
            if (headerParts.length == 2) {
              int chunkIndex = int.tryParse(headerParts[0]) ?? 0;
              int totalChunks = int.tryParse(headerParts[1]) ?? 0;
              
              if (chunkIndex > 0 && totalChunks > 0) {
                print("📶 Received chunk $chunkIndex of $totalChunks");
                _wifiScanChunks[chunkIndex] = data;
                _totalWifiScanChunks = totalChunks;
                
                // Check if we have all chunks
                if (_wifiScanChunks.length == _totalWifiScanChunks) {
                  // Combine all chunks in order
                  String completeData = '';
                  for (int i = 1; i <= _totalWifiScanChunks; i++) {
                    completeData += _wifiScanChunks[i] ?? '';
                  }
                  
                  print("📶 Complete WiFi scan data: $completeData");
                  _processWifiScanData(completeData);
                  
                  // Cancel the subscription
                  subscription?.cancel();
                }
              }
            }
          } else {
            // Handle non-chunked data (single response)
            print("📶 Received non-chunked data: $chunkData");
            _processWifiScanData(chunkData);
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
            print("📡 Scan trigger sent successfully");
          } catch (e) {
            print("⚠️ Could not write to trigger scan: $e");
            print("⚠️ Falling back to read-only mode");
          }
        } else {
          print("ℹ️ Characteristic doesn't support write, using read-only mode");
        }
        
        // Read the characteristic to start receiving notifications
        try {
          await wifiScanCharacteristic.read();
          print("📡 Initial read completed");
        } catch (e) {
          print("⚠️ Error reading characteristic: $e");
        }
        
        // Set a timeout to cancel the subscription if we don't receive all chunks
        Future.delayed(Duration(seconds: 10), () {
          if (_isScanningWifi) {
            subscription?.cancel();
            
            // Process whatever chunks we have if we got at least one
            if (_wifiScanChunks.isNotEmpty) {
              String partialData = '';
              for (int i = 1; i <= _totalWifiScanChunks; i++) {
                if (_wifiScanChunks.containsKey(i)) {
                  partialData += _wifiScanChunks[i] ?? '';
                }
              }
              
              if (partialData.isNotEmpty) {
                print("📶 Processing partial WiFi scan data: $partialData");
                _processWifiScanData(partialData);
              } else {
                setState(() {
                  _isScanningWifi = false;
                  _statusMessage = 'Failed to receive WiFi scan data.';
                });
              }
            } else {
              setState(() {
                _isScanningWifi = false;
                _statusMessage = 'Failed to receive WiFi scan data.';
              });
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
    List<String> networks = WifiUtils.processWifiScanData(wifiString);
    
    setState(() {
      _wifiNetworks = networks;
      _isScanningWifi = false;
      _statusMessage = 'Found ${_wifiNetworks.length} WiFi networks';
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
