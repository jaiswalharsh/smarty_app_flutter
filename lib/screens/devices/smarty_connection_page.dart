import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ble_manager.dart';
import '../../services/ble_service.dart';
import '../wifi/wifi_config_page.dart';
import 'device_registration_page.dart';

class SmartyConnectionPage extends StatefulWidget {
  const SmartyConnectionPage({super.key});

  @override
  SmartyConnectionPageState createState() => SmartyConnectionPageState();
}

class SmartyConnectionPageState extends State<SmartyConnectionPage> {
  final BleManager _bleManager = BleManager();
  String _connectionResult = '';
  bool _isScanning = false;
  bool _isCheckingConnectedDevices = true;
  StreamSubscription? _showSnackBarSubscription;
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  // Why the last scan came up empty — drives the actionable empty-state UI.
  BleScanIssue _lastScanIssue = BleScanIssue.none;
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
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });

    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((status) {
      if (status == "NotConnected" && mounted) {
        setState(() {
          _connectionResult = 'Device disconnected';
        });
        _checkForConnectedSmartyDevice();
      }
    });

    // Track the adapter live so turning Bluetooth off/on mid-page updates the
    // UI instead of stranding the parent on a stale "no devices" screen.
    _adapterStateSubscription =
        FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      if (state == BluetoothAdapterState.off ||
          state == BluetoothAdapterState.turningOff) {
        setState(() {
          _isScanning = false;
          _isCheckingConnectedDevices = false;
          _lastScanIssue = BleScanIssue.bluetoothOff;
        });
      } else if (state == BluetoothAdapterState.on &&
          _lastScanIssue == BleScanIssue.bluetoothOff &&
          _discoveredDevices.isEmpty &&
          !_isScanning) {
        // Came back on after we'd flagged it off — pick the scan back up.
        _startScanning();
      }
    });
  }

  @override
  void dispose() {
    _showSnackBarSubscription?.cancel();
    _wifiStatusSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkForConnectedSmartyDevice() async {
    setState(() {
      _isCheckingConnectedDevices = true;
      _connectionResult = 'Checking for connected devices...';
    });

    try {
      // First check if Bluetooth is enabled
      bool isBluetoothReady = await BleService.isBluetoothReady();
      if (!mounted) return;
      if (!isBluetoothReady) {
        // Use the native method to request Bluetooth be turned on
        try {
          await FlutterBluePlus.turnOn();
        } catch (e) {
          print("Error requesting Bluetooth: $e");
        }
        if (!mounted) return;

        // Check again if Bluetooth got enabled
        isBluetoothReady = await BleService.isBluetoothReady();
        if (!mounted) return;
        if (!isBluetoothReady) {
          // Show the actionable "Bluetooth is off" state instead of a passive
          // banner with no fix.
          setState(() {
            _isCheckingConnectedDevices = false;
            _connectionResult = '';
            _lastScanIssue = BleScanIssue.bluetoothOff;
          });
          return;
        }
      }

      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();
      if (!mounted) return;

      if (restored) {
        setState(() {
          _isCheckingConnectedDevices = false;
          _connectionResult =
              'Connected to ${_bleManager.connectedDevice?.platformName ?? "Smarty device"}';
        });
        _handleConnectionSuccess(_bleManager.connectedDevice!);
        return;
      }

      // Try auto-reconnect to saved device
      bool autoReconnected = await _bleManager.autoReconnectToSavedDevice();
      if (!mounted) return;
      if (autoReconnected && _bleManager.connectedDevice != null) {
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
      if (!mounted) return;

      for (BluetoothDevice device in connectedDevices) {
        if (device.platformName.toLowerCase().contains("smarty")) {
          await _bleManager.initialize(device);
          if (!mounted) return;
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
      if (!mounted) return;
      if (isBluetoothReady) {
        _startScanning();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCheckingConnectedDevices = false;
        _connectionResult = 'Error: $e';
      });

      // Check Bluetooth status before attempting to scan
      bool isBluetoothReady = await BleService.isBluetoothReady();
      if (!mounted) return;
      if (isBluetoothReady) {
        _startScanning();
      }
    }
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _lastScanIssue = BleScanIssue.none;
      _discoveredDevices.clear();
    });

    try {
      // The scan classifies Bluetooth-off / permission / unsupported blockers
      // itself, so the empty state can offer the right fix instead of a silent
      // "nothing found".
      final BleScanIssue issue =
          await BleService.scanForSmartyDevicesWithCallback(_onDeviceDiscovered);
      if (!mounted) return;
      setState(() {
        _lastScanIssue = issue;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastScanIssue = BleScanIssue.unknown;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  void _onDeviceDiscovered(ScanResult result) {
    if (!mounted) return;
    final alreadyExists = _discoveredDevices.any(
      (d) => d.remoteId == result.device.remoteId,
    );
    if (!alreadyExists) {
      setState(() {
        _discoveredDevices.add(result.device);
      });
    }
  }

  // Bluetooth-off recovery: Android can show the system turn-on dialog; iOS has
  // no programmatic turn-on, so send the parent to settings. Rescan once it's on.
  Future<void> _handleTurnOnBluetooth() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print("Error turning on Bluetooth: $e");
        await BleService.openBluetoothSettings();
      }
    } else {
      await BleService.openBluetoothSettings();
    }
    if (!mounted) return;
    final bool ready = await BleService.isBluetoothReady();
    if (!mounted) return;
    if (ready) {
      _startScanning();
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _connectionResult = 'Connecting to ${device.platformName}...';
    });

    try {
      await device.connect(timeout: const Duration(seconds: 10));

      await _bleManager.initialize(device);

      if (!mounted) return;

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is TimeoutException || e.toString().contains('timed out')) {
          _connectionResult =
              'Connection timed out. Device may be out of range.';
        } else {
          _connectionResult = 'Failed to connect: $e';
        }
      });
      // Kick off a rescan AFTER the state update, not inside setState() — starting
      // an async scan (which itself calls setState) from within a build-state
      // mutation is fragile and can throw "setState during build" (APP-6).
      _startScanning();
    }
  }

  Future<void> _handleConnectionSuccess(BluetoothDevice device) async {
    // Refresh status first so `deviceRegistered` reflects THIS toy before we
    // decide anything. (`_connectToDevice` already reads status before calling
    // us; a second read is idempotent and cheap — uniformity wins.)
    try {
      await _bleManager.readStatusUpdate();
    } catch (_) {}
    if (!mounted) return;

    // Work out whether the toy still needs Firebase registration. Until it's
    // registered it holds no device secret and can't reach the backend at all,
    // so this isn't optional polish — an unregistered toy simply can't talk.
    bool needsRegistration = false;
    String? deviceId;
    // True only when the decision came from the local fallback below (old
    // firmware that can't report the flag). Gates whether we persist success.
    bool usedLocalFallback = false;

    if (_bleManager.deviceRegistered == true) {
      // Toy reports it already holds its secret — nothing to do.
      needsRegistration = false;
    } else {
      // Need the id both to register and to key the local fallback record.
      deviceId = await _bleManager.readDeviceId();
      if (!mounted) return;
      final bool deviceIdReadable =
          deviceId != null && deviceId.isNotEmpty && deviceId != '{}';
      if (!deviceIdReadable) {
        // No readable id → can't register, so leave it (existing behavior).
        needsRegistration = false;
      } else if (_bleManager.deviceRegistered == false) {
        // Toy explicitly reports it has no secret yet.
        needsRegistration = true;
      } else {
        // deviceRegistered == null: firmware predates the status field, so the
        // toy can't tell us. Fall back to a local record. Honest limits: it is
        // device-scoped (registration is a property of the toy, not the
        // account) and only backs up firmware that can't report the flag —
        // whenever firmware does report it, that report wins in the branches
        // above and this record is ignored.
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        needsRegistration =
            !(prefs.getBool('device_registered_$deviceId') ?? false);
        usedLocalFallback = true;
      }
    }

    if (needsRegistration && mounted) {
      // Keep offering registration until it succeeds or the parent knowingly
      // picks "Later". The old code pushed once and, on any back-out, printed a
      // note and proceeded as if all was well — which it wasn't.
      while (mounted) {
        final bool? registered = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => DeviceRegistrationPage()),
        );
        if (!mounted) return;
        if (registered == true) {
          // Only the null-flag fallback path needs a local record; when the
          // firmware reports the flag the toy is authoritative (and stays
          // correct across factory resets), so we write nothing there.
          if (usedLocalFallback && deviceId != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('device_registered_$deviceId', true);
            if (!mounted) return;
          }
          break;
        }
        // Backed out (back button or "Not now"). Be honest about the cost and
        // offer to retry now, or to be reminded on the next connect.
        final bool? tryAgain = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: Text('Registration not finished'),
              content: Text(
                "Smarty isn't registered yet, so it won't be able to talk with "
                "your child. You can finish this now, or we'll remind you the "
                "next time you connect.",
                style: TextStyle(fontSize: 16),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text('Later'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade600,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text('Try Again'),
                ),
              ],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            );
          },
        );
        if (!mounted) return;
        if (tryAgain != true) {
          // "Later" (or dismissed): stop prompting and fall through to WiFi
          // setup, which is still worth doing. Nothing was recorded and the toy
          // still reports unregistered, so the next connect re-prompts — exactly
          // what the dialog promised.
          break;
        }
        // "Try Again": loop back and push the registration page again.
      }
    }

    // Wait for a definitive WiFi status — the device may report
    // transient states like "Init" right after BLE connection
    for (int i = 0; i < 3; i++) {
      if (!mounted) return;
      if (_bleManager.isWifiConnected) {
        Navigator.of(context).pop();
        return;
      }
      // Give the device time to connect to WiFi before re-reading
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
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
      builder: (BuildContext dialogContext) {
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
                // Close the dialog on ITS OWN context, then pop the page on the
                // page's context — popping twice on the dialog context runs the
                // second pop against a route that's already gone.
                Navigator.of(dialogContext).pop(); // Close dialog
                Navigator.of(context).pop(); // Return to HomeTab
              },
              child: Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop(); // Close dialog
                // popOnSuccess makes the WiFi stack pop `true` all the way up
                // once the toy actually joins a network; forward that to Home
                // so it can show the "you're done!" celebration.
                final bool? provisioned = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        WifiConfigPage(popOnSuccess: true),
                  ),
                );
                if (provisioned == true && mounted) {
                  Navigator.pop(context, true);
                }
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

  // Turns the last scan issue into an empty-state view with the right fix,
  // instead of a passive "nothing found" for every cause.
  Widget _buildScanIssueView() {
    switch (_lastScanIssue) {
      case BleScanIssue.bluetoothOff:
        return _buildActionableIssueView(
          icon: Icons.bluetooth_disabled,
          title: 'Bluetooth is turned off.',
          message:
              'Smarty connects over Bluetooth. Turn it on to find your toy.',
          actionLabel: 'Turn on Bluetooth',
          onAction: _handleTurnOnBluetooth,
        );
      case BleScanIssue.permissionDenied:
        return _buildActionableIssueView(
          icon: Icons.lock_outline,
          title: 'Bluetooth permission needed',
          message: 'Smarty needs Bluetooth permission to find your toy. '
              'You can turn it on in Settings.',
          actionLabel: 'Open app settings',
          onAction: BleService.openAppPermissionSettings,
          showRescan: true,
        );
      case BleScanIssue.unsupported:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Text(
              "This phone doesn't support the Bluetooth features Smarty needs, "
              "so it can't connect here.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey[700]),
            ),
          ),
        );
      case BleScanIssue.unknown:
        return _buildActionableIssueView(
          icon: Icons.error_outline,
          title: 'Something went wrong',
          message:
              "We couldn't finish looking for your Smarty. Please try again.",
          actionLabel: 'Scan Again',
          onAction: _startScanning,
        );
      case BleScanIssue.none:
        return _buildNoDevicesFoundView();
    }
  }

  Widget _buildActionableIssueView({
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    bool showRescan = false,
  }) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey[400]),
              SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[700],
                ),
              ),
              SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              SizedBox(height: 24),
              ElevatedButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
              if (showRescan) ...[
                SizedBox(height: 12),
                TextButton.icon(
                  icon: Icon(Icons.refresh),
                  label: Text('Scan Again'),
                  onPressed: _startScanning,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Scan ran fine but found nothing — most likely the toy isn't in pairing mode.
  Widget _buildNoDevicesFoundView() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bluetooth_searching, size: 48, color: Colors.grey[400]),
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
              'Make sure your Smarty is powered on and in pairing mode',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
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
                      constraints: BoxConstraints(maxWidth: 350),
                      child: Text(
                        'Tip: To enter pairing mode, press Vol + and Vol - together for 3 seconds',
                        softWrap: true,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
                    ? _buildScanIssueView()
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
