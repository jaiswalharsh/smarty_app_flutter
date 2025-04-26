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

  @override
  void initState() {
    super.initState();
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
      _startScanning();
    } catch (e) {
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
      _devices = [];
      _connectionResult = '';
    });

    try {
      StreamSubscription<List<ScanResult>>? subscription;
      subscription = BleService.scanForSmartyDevices().listen((results) {
        setState(() {
          _devices = results.map((result) => result.device).toList();
        });
      });

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

  void _handleConnectionSuccess(BluetoothDevice device) {
    if (_bleManager.isWifiConnected) {
      // If WiFi is already connected, navigate back to HomeTab
      Navigator.of(context).pop();
    } else {
      // Show popup to ask about WiFi setup
      _showWifiSetupPopup(device);
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
                  color: Colors.white70,
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
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
              SizedBox(height: 12),
              Text(
                'Would you like to set up WiFi now?',
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                Navigator.of(context).pop(); // Return to HomeTab
              },
              child: Text(
                'Skip',
                style: TextStyle(color: Colors.white70),
              ),
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
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Checking for connected devices...'),
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
                            _connectionResult.contains('timed out')
                        ? Colors.red.withOpacity(0.1)
                        : _connectionResult.contains('Connecting')
                        ? Colors.blue.withOpacity(0.1)
                        : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _connectionResult.contains('Failed') ||
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
                  color:
                      _connectionResult.contains('Failed') ||
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
          ElevatedButton.icon(
            icon: Icon(Icons.bluetooth_searching),
            label: Text(
              _isScanning ? 'Scanning...' : 'Scan for Smarty Devices',
            ),
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
