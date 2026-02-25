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
  final BleManager _bleManager = BleManager();
  String _connectionResult = '';
  List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  bool _isCheckingConnectedDevices = true;
  StreamSubscription? _showSnackBarSubscription;
  StreamSubscription? _deviceConnectionSubscription;
  String _scanningStatus = '';
  final List<BluetoothDevice> _discoveredDevices = [];

  @override
  void initState() {
    super.initState();
    
    // Initialize BleService with context for Bluetooth prompts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        BleService.initialize(context);
      }
    });
    
    _checkForConnectedSmartyDevice();

    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((
      message,
    ) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });

    _subscribeToConnectionChanges();
  }

  @override
  void dispose() {
    _showSnackBarSubscription?.cancel();
    _deviceConnectionSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToConnectionChanges() {
    if (_bleManager.connectedDevice != null) {
      _deviceConnectionSubscription?.cancel();
      _deviceConnectionSubscription = _bleManager
          .connectedDevice!
          .connectionState
          .listen((state) {
            if (state == BluetoothConnectionState.disconnected) {
              setState(() {
                _devices = [];
                _connectionResult = 'Device disconnected';
              });
              _checkForConnectedSmartyDevice();
            }
          });
    }
  }

  Future<void> _checkForConnectedSmartyDevice() async {
    setState(() {
      _isCheckingConnectedDevices = true;
      _connectionResult = 'Checking for connected devices...';
    });

    try {
      // First check if Bluetooth is enabled
      bool isBluetoothReady = await BleService.isBluetoothReady();
      if (!isBluetoothReady) {
        // Use the native method to request Bluetooth be turned on
        try {
          await FlutterBluePlus.turnOn();
        } catch (e) {
          print("Error requesting Bluetooth: $e");
        }
        
        // Check again if Bluetooth got enabled
        isBluetoothReady = await BleService.isBluetoothReady();
        if (!isBluetoothReady) {
          setState(() {
            _isCheckingConnectedDevices = false;
            _connectionResult = 'Bluetooth is required for device connections. Please enable it in your device settings.';
          });
          return;
        }
      }
      
      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();

      if (restored) {
        setState(() {
          _isCheckingConnectedDevices = false;
          _connectionResult =
              'Connected to ${_bleManager.connectedDevice?.platformName ?? "Smarty device"}';
        });
        _handleConnectionSuccess(_bleManager.connectedDevice!);
        return;
      }

      // Use the regular method since we already checked Bluetooth status
      List<BluetoothDevice> connectedDevices =
          await BleService.getConnectedDevices();

      for (BluetoothDevice device in connectedDevices) {
        if (device.platformName.toLowerCase().contains("smarty")) {
          await _bleManager.initialize(device);
          _subscribeToConnectionChanges();
          setState(() {
            _isCheckingConnectedDevices = false;
            _connectionResult = 'Connected to ${device.platformName}';
          });
          _handleConnectionSuccess(device);
          return;
        }
      }

      setState(() {
        _isCheckingConnectedDevices = false;
        _connectionResult = 'No connected devices found';
      });
      
      // Check Bluetooth again before scanning - it might have been turned off
      isBluetoothReady = await BleService.isBluetoothReady();
      if (isBluetoothReady) {
        _startScanning();
      }
    } catch (e) {
      setState(() {
        _isCheckingConnectedDevices = false;
        _connectionResult = 'Error: $e';
      });
      
      // Check Bluetooth status before attempting to scan
      bool isBluetoothReady = await BleService.isBluetoothReady();
      if (isBluetoothReady) {
        _startScanning();
      }
    }
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _scanningStatus = 'Scanning for Smarty devices...';
      _discoveredDevices.clear();
    });

    try {
      bool isBluetoothReady = await BleService.isBluetoothReady();
      if (!isBluetoothReady) {
        // Try to turn on Bluetooth using the system dialog
        try {
          await FlutterBluePlus.turnOn();
        } catch (e) {
          print("Error requesting Bluetooth: $e");
        }
        
        // Check again if Bluetooth got enabled
        isBluetoothReady = await BleService.isBluetoothReady();
        if (!isBluetoothReady) {
          setState(() {
            _isScanning = false;
            _scanningStatus = 'Bluetooth is required for scanning. Please enable it in your device settings.';
          });
          return;
        }
      }

      // Use the regular scan method since we already checked Bluetooth
      await BleService.scanForSmartyDevicesWithCallback(_onDeviceDiscovered);
      
      // Handle no devices found after scan completes
      if (_discoveredDevices.isEmpty) {
        setState(() {
          _scanningStatus = 'No Smarty devices found';
        });
      } else {
        setState(() {
          _scanningStatus = 'Found ${_discoveredDevices.length} Smarty device(s)';
        });
      }
    } catch (e) {
      setState(() {
        _scanningStatus = 'Error: $e';
      });
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  void _onDeviceDiscovered(ScanResult result) {
    final alreadyExists = _discoveredDevices.any(
      (d) => d.remoteId == result.device.remoteId,
    );
    if (!alreadyExists) {
      setState(() {
        _discoveredDevices.add(result.device);
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _connectionResult = 'Connecting to ${device.platformName}...';
    });

    try {
      bool connectionSuccessful = false;

      await Future.any([
        device.connect().then((_) {
          connectionSuccessful = true;
        }),
        Future.delayed(Duration(seconds: 10)).then((_) {
          if (!connectionSuccessful) {
            throw TimeoutException('Connection attempt timed out');
          }
        }),
      ]);

      if (connectionSuccessful) {
        await _bleManager.initialize(device);
        _subscribeToConnectionChanges();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${device.platformName}'),
            backgroundColor: Colors.green,
          ),
        );

        setState(() {
          _connectionResult = 'Connected to ${device.platformName}';
        });

        await Future.delayed(Duration(milliseconds: 500));
        await _bleManager.readStatusUpdate();

        _handleConnectionSuccess(device);
      }
    } catch (e) {
      setState(() {
        if (e is TimeoutException) {
          _connectionResult =
              'Connection timed out. Device may be out of range.';
        } else {
          _connectionResult = 'Failed to connect: $e';
        }
        _startScanning();
      });
    }
  }

  Future<void> _handleConnectionSuccess(BluetoothDevice device) async {
    // Wait for a definitive WiFi status — the device may report
    // transient states like "Init" right after BLE connection
    for (int i = 0; i < 5; i++) {
      if (_bleManager.isWifiConnected) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // If status is still unknown/transient, wait and re-read
      await Future.delayed(const Duration(milliseconds: 500));
      await _bleManager.readStatusUpdate();
    }

    // After retries, if still not connected, show WiFi setup
    if (mounted) {
      if (_bleManager.isWifiConnected) {
        Navigator.of(context).pop();
      } else {
        _showWifiSetupPopup(device);
      }
    }
  }

  void _showWifiSetupPopup(BluetoothDevice device) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.bluetooth, color: Colors.blue.shade600, size: 24),
              SizedBox(width: 8),
              Text(
                'Smarty Connected',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your Smarty is not connected to any WiFi network. Please connect to a WiFi network to use the Smarty.',
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 12),
              Text(
                'Would you like to set up WiFi now?',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                Navigator.of(context).pop(); // Return to HomeTab
              },
              child: Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => WifiConfigPage()),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text('Set Up WiFi'),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
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
        body:
            _isCheckingConnectedDevices
                ? _buildLoadingView()
                : _buildContentView(),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            _connectionResult.isEmpty 
                ? 'Checking for connected devices...' 
                : _connectionResult,
            textAlign: TextAlign.center,
          ),
          
          // Show Bluetooth instructions if relevant
          if (_connectionResult.contains('Bluetooth'))
            Padding(
              padding: const EdgeInsets.only(top: 24.0),
              child: Column(
                children: [
                  Icon(Icons.bluetooth_disabled, size: 48, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Please enable Bluetooth in your device settings',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(height: 24),
                  ElevatedButton.icon(
                    icon: Icon(Icons.refresh),
                    label: Text('Try Again'),
                    onPressed: () => _checkForConnectedSmartyDevice(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContentView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_connectionResult.isNotEmpty)
            Container(
              margin: EdgeInsets.only(bottom: 16),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    _connectionResult.contains('Failed') ||
                            _connectionResult.contains('Error') ||
                            _connectionResult.contains('timed out') ||
                            _connectionResult.contains('Bluetooth is disabled')
                        ? Colors.red.withOpacity(0.1)
                        : _connectionResult.contains('Connecting')
                        ? Colors.blue.withOpacity(0.1)
                        : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _connectionResult.contains('Failed') ||
                              _connectionResult.contains('Error') ||
                              _connectionResult.contains('timed out') ||
                              _connectionResult.contains('Bluetooth is disabled')
                          ? Colors.red
                          : _connectionResult.contains('Connecting')
                          ? Colors.blue
                          : Colors.green,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _connectionResult,
                    style: TextStyle(
                      color:
                          _connectionResult.contains('Failed') ||
                                  _connectionResult.contains('Error') ||
                                  _connectionResult.contains('timed out') ||
                                  _connectionResult.contains('Bluetooth is disabled')
                              ? Colors.red
                              : _connectionResult.contains('Connecting')
                              ? Colors.blue
                              : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  
                  // Add button to open Bluetooth settings if needed
                  if (_connectionResult.contains('Bluetooth is required') || _connectionResult.contains('Bluetooth turned off'))
                    Padding(
                      padding: const EdgeInsets.only(top: 12.0),
                      child: Text(
                        'Please enable Bluetooth in your device settings',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ElevatedButton.icon(
            icon: Icon(Icons.bluetooth_searching),
            label: Text(_isScanning ? 'Scanning...' : 'Look for your Smarty'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _isScanning ? null : _startScanning,
          ),
          SizedBox(height: 16),
          Expanded(
            child:
                _isScanning
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
                    : _discoveredDevices.isEmpty
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
                            'Make sure your device is powered on and in pairing mode',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          SizedBox(height: 8),
                          // Updated tip section
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ), // Add padding to constrain width
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.lightbulb_outline,
                                  size: 16,
                                  color: Colors.grey[600],
                                ),
                                SizedBox(width: 4),
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          350, // Explicitly limit the text width
                                    ),
                                    child: Text(
                                      'Tip: To enter pairing mode, press Vol + and Vol - together for 3 seconds',
                                      softWrap: true,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
                            itemCount: _discoveredDevices.length,
                            itemBuilder: (context, index) {
                              final device = _discoveredDevices[index];
                              return Card(
                                elevation: 2,
                                margin: EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  title: Text(
                                    device.platformName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
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
