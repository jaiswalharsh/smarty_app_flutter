import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'screens/devices/smarty_connection_page.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with SingleTickerProviderStateMixin {
  // BLE manager
  final BleManager _bleManager = BleManager();

  // Animation controller for success animation
  late AnimationController _animationController;
  bool _showSuccessState = false;
  
  // Status information
  String _connectedWifi = "Unknown";
  String _batteryLevel = "Unknown";

  // Stream subscriptions
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription? _batteryStatusSubscription;
  StreamSubscription? _wifiStatusMessageSubscription;
  StreamSubscription? _showSnackBarSubscription;

  // New variable for connecting device
  bool _isConnectingDevice = false;
  BluetoothDevice? _connectedDevice;

  @override
  void initState() {
    super.initState();
    
    // Only perform device check during initial load, not when switching tabs
    if (mounted) {
      // Set up a post-frame callback to avoid UI stutters
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initialDeviceCheck();
      });
    }
    
    // Listen for status updates
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      if (!mounted) return; // Check if still mounted
      setState(() {
        _connectedWifi = wifiName;
        // Reset the UI if the device is disconnected
        if (wifiName == "NotConnected") {
          // print("📱 HomeTab: Detected device disconnection");
          _connectedDevice = null;
          // Force UI to show the disconnected view
          setState(() {});
        }
      });
    });

    _batteryStatusSubscription = _bleManager.batteryStatusStream.listen((
      batteryLevel,
    ) {
      if (!mounted) return; // Check if still mounted
      setState(() {
        _batteryLevel = batteryLevel.toString();
      });
    });

    // Listen for snackbar notifications
    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((
      message,
    ) {
      if (!mounted) return; // Check if still mounted
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
    
    // Initialize animation controller
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _wifiStatusSubscription?.cancel();
    _batteryStatusSubscription?.cancel();
    _wifiStatusMessageSubscription?.cancel();
    _showSnackBarSubscription?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  // One-time initial device check performed only when tab is first created
  void _initialDeviceCheck() {
    // Get the current connection state instead of running a check
    if (_bleManager.isConnected) {
      // print("✅ HomeTab: BLE manager already has a connected device");
      _connectedDevice = _bleManager.connectedDevice;
      _connectedWifi = _bleManager.connectedWifi;
      _batteryLevel = _bleManager.batteryLevel.toString();
      
      // No need to show loading indicators when switching tabs
      if (mounted) {
        setState(() {
          _isConnectingDevice = false;
        });
      }
    } else {
      // If no connection exists, perform the usual check
      _checkForConnectedDevices();
    }
  }

  // Check if we already have a connected device
  Future<void> _checkForConnectedDevices() async {
    if (!mounted) return; // Prevent executing if widget is not mounted
    
    try {
      // print("🔄 HomeTab: Checking for connected devices after possible hot restart");
      
      // Show reconnecting state but allow UI to render
      setState(() {
        _isConnectingDevice = true;
      });
      
      // Get connected devices immediately to update UI state
      List<BluetoothDevice> connectedDevices = await BleService.getConnectedDevices();
      
      if (!mounted) return; // Check again after async operation
      
      // Immediately show connected UI if we have a device
      if (connectedDevices.isNotEmpty) {
        // Find the first device with "Smarty" in the name
        for (BluetoothDevice device in connectedDevices) {
          if (device.platformName.toLowerCase().contains("smarty")) {
            // print("✅ HomeTab: Found connected Smarty device: ${device.platformName}");
            
            // Initialize the BLE manager with this device to start the connection process
            // but don't wait for it to complete before updating UI
            _bleManager.initialize(device);
            
            // Set the device as connected in the UI immediately
            if (mounted) {
              setState(() {
                _connectedDevice = device;
              });
            }
            
            // Continue status update in the background
            _fetchStatusInBackground(device);
            return;
          }
        }
      }
      
      if (!mounted) return; // Check again after async operation
      
      // If we couldn't find a connected device immediately, try the restore process
      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();
      
      if (!mounted) return; // Check again after async operation
      
      if (restored) {
        // print("✅ HomeTab: Successfully restored connection after hot restart");
        
        // Update the UI with current values
        setState(() {
          _connectedWifi = _bleManager.connectedWifi;
          _batteryLevel = _bleManager.batteryLevel.toString();
          _isConnectingDevice = false;
        });
      } else {
        // print("ℹ️ HomeTab: No connected devices found");
        if (mounted) {
          setState(() {
            _isConnectingDevice = false;
          });
        }
      }
    } catch (e) {
      // print("❌ HomeTab: Error checking for connected devices: $e");
      if (mounted) {
        setState(() {
          _isConnectingDevice = false;
        });
      }
    }
  }
  
  // Fetch device status in the background to avoid blocking the UI
  Future<void> _fetchStatusInBackground(BluetoothDevice device) async {
    try {
      // Check if we already have valid status data
      if (_connectedWifi != "Unknown" && _batteryLevel != "Unknown") {
        // If we already have data, just update the loading state
        if (mounted) {
          setState(() {
            _isConnectingDevice = false;
          });
        }
        return;
      }
      
      // Wait for initialization to complete if needed
      await Future.delayed(Duration(milliseconds: 1000));
      
      if (!mounted) return; // Check after delay
      
      // Read status update if we don't have data yet
      await _bleManager.readStatusUpdate();
      
      if (!mounted) return; // Check after async call
      
      // Update UI with the status data
      setState(() {
        _connectedWifi = _bleManager.connectedWifi;
        _batteryLevel = _bleManager.batteryLevel.toString();
        _isConnectingDevice = false;
      });
    } catch (e) {
      // print("❌ HomeTab: Error fetching device status: $e");
      if (mounted) {
        setState(() {
          _isConnectingDevice = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if we have a device connected either through the manager or directly
    bool isDeviceConnected = _bleManager.isConnected || _connectedDevice != null;
    
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
            child: isDeviceConnected
                ? _showSuccessState
                    ? _buildSuccessView()
                    : _buildConnectedView()
                : _buildDeviceNotConnectedView(),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceNotConnectedView() {
    if (_isConnectingDevice) {
      return _buildReconnectingView();
    }
    
    return _buildDisconnectedView();
  }
  
  // Original disconnected view
  Widget _buildDisconnectedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/icon.png',
            width: 120,
            height: 120,
          ),
          SizedBox(height: 24),
          
          // Title
          Text(
            'Connect to Smarty',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          
          SizedBox(height: 16),
          
          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Text(
              'Connect to your Smarty toy to start playing and learning together',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          
          SizedBox(height: 32),
          
          // Connect button
          ElevatedButton.icon(
            icon: Icon(Icons.bluetooth_searching, size: 24),
            label: Text(
              'Connect to Smarty',
              style: TextStyle(fontSize: 18),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade500,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 4,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
              ).then((_) {
                // Refresh state when returning from config page
                _checkForConnectedDevices();
              });
            },
          ),
          SizedBox(height: 16),
          
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.yellow.shade100,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.yellow.shade300, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline, color: Colors.orange),
                SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Connect your Smarty toy to get started!',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView() {
    // Only show loading indicators when we're actually connecting a device,
    // not when just switching tabs with an already connected device
    bool showLoadingIndicators = _isConnectingDevice && 
        (_connectedWifi == "Unknown" || _batteryLevel == "Unknown");
    
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fun animated header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20.0),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.purple.shade300, Colors.blue.shade300],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Image.asset(
                        'assets/images/icon.png',
                        width: 32,
                        height: 32,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smarty is Online!',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          showLoadingIndicators ? 'Updating status...' : 'Ready to play and learn',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 20),
                Container(
                  padding: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      showLoadingIndicators && _connectedWifi == "Unknown"
                          ? SizedBox(
                              width: 16, 
                              height: 16, 
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              )
                            )
                          : Icon(
                              _bleManager.isWifiConnected ? Icons.wifi : Icons.wifi_off,
                              color: _bleManager.isWifiConnected ? Colors.green : Colors.orange,
                            ),
                      SizedBox(width: 8),
                      Text(
                        showLoadingIndicators && _connectedWifi == "Unknown"
                            ? 'Updating WiFi status...'
                            : (_bleManager.isWifiConnected ? 'Connected to $_connectedWifi' : 'WiFi not connected'),
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 10),
                Container(
                  padding: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      showLoadingIndicators && _batteryLevel == "Unknown"
                          ? SizedBox(
                              width: 16, 
                              height: 16, 
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              )
                            )
                          : Icon(
                              _getBatteryIcon(),
                              color: _getBatteryColor(),
                            ),
                      SizedBox(width: 8),
                      Text(
                        showLoadingIndicators && _batteryLevel == "Unknown"
                            ? 'Updating battery status...'
                            : 'Battery: $_batteryLevel%',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 32),

          // Welcome Card - replacing profile form
          // Card(
          //   elevation: 4,
          //   shape: RoundedRectangleBorder(
          //     borderRadius: BorderRadius.circular(16),
          //   ),
          //   child: Padding(
          //     padding: const EdgeInsets.all(20.0),
          //     child: Column(
          //       crossAxisAlignment: CrossAxisAlignment.start,
          //       children: [
          //         Row(
          //           children: [
          //             Icon(Icons.celebration, color: Colors.orange, size: 32),
          //             SizedBox(width: 12),
          //             Text(
          //               'Your Smarty is Ready!',
          //               style: TextStyle(
          //                 fontSize: 22,
          //                 fontWeight: FontWeight.bold,
          //                 color: Colors.blue.shade800,
          //               ),
          //             ),
          //           ],
          //         ),
          //         SizedBox(height: 16),
          //         Text(
          //           'Your Smarty toy is connected and ready to use. Enjoy playing and learning with your smart companion!',
          //           style: TextStyle(
          //             fontSize: 16,
          //             color: Colors.grey.shade700,
          //           ),
          //         ),
          //         SizedBox(height: 20),
          //         // Tips section
          //         Container(
          //           padding: EdgeInsets.all(16),
          //           decoration: BoxDecoration(
          //             color: Colors.blue.shade50,
          //             borderRadius: BorderRadius.circular(12),
          //             border: Border.all(color: Colors.blue.shade100),
          //           ),
          //           child: Column(
          //             crossAxisAlignment: CrossAxisAlignment.start,
          //             children: [
          //               Text(
          //                 'Quick Tips:',
          //                 style: TextStyle(
          //                   fontWeight: FontWeight.bold,
          //                   fontSize: 16,
          //                   color: Colors.blue.shade800,
          //                 ),
          //               ),
          //               SizedBox(height: 12),
          //               _buildTipItem(
          //                 Icons.wifi, 
          //                 'Configure WiFi in Settings to enable online features'
          //               ),
          //               SizedBox(height: 8),
          //               _buildTipItem(
          //                 Icons.battery_charging_full, 
          //                 'Keep Smarty charged for best performance'
          //               ),
          //               SizedBox(height: 8),
          //               _buildTipItem(
          //                 Icons.bluetooth, 
          //                 'Stay within 30 feet of Smarty for a stable connection'
          //               ),
          //             ],
          //           ),
          //         ),
          //       ],
          //     ),
          //   ),
          // ),
        ],
      ),
    );
  }
  
  // Helper method for quick tips
  // Widget _buildTipItem(IconData icon, String text) {
  //   return Row(
  //     crossAxisAlignment: CrossAxisAlignment.start,
  //     children: [
  //       Icon(icon, size: 18, color: Colors.blue.shade700),
  //       SizedBox(width: 8),
  //       Expanded(
  //         child: Text(
  //           text,
  //           style: TextStyle(color: Colors.blue.shade700),
  //         ),
  //       ),
  //     ],
  //   );
  // }

  // Success view with celebration animation
  Widget _buildSuccessView() {
    return Stack(
      children: [
        // Content
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Success icon with animation
              AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return Transform.scale(
                    scale: 0.5 + (_animationController.value * 0.5),
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 80,
                        color: Colors.green,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: 32),
              // Success message
              Text(
                'Connection Successful!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Your Smarty device is ready to use!',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 48),
              // Continue button
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showSuccessState = false;
                  });
                },
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  backgroundColor: Colors.blue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  'Continue',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Confetti overlay
        AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return _animationController.value > 0
                ? CustomPaint(
                    painter: ConfettiPainter(
                      progress: _animationController.value,
                    ),
                    size: Size.infinite,
                  )
                : SizedBox.shrink();
          },
        ),
      ],
    );
  }
  
  // Helper methods for battery icon
  IconData _getBatteryIcon() {
    int level = int.tryParse(_batteryLevel) ?? 0;
    if (level >= 90) return Icons.battery_full;
    if (level >= 70) return Icons.battery_6_bar;
    if (level >= 50) return Icons.battery_4_bar;
    if (level >= 30) return Icons.battery_3_bar;
    if (level >= 20) return Icons.battery_2_bar;
    if (level >= 10) return Icons.battery_1_bar;
    return Icons.battery_0_bar;
  }
  
  Color _getBatteryColor() {
    int level = int.tryParse(_batteryLevel) ?? 0;
    if (level >= 50) return Colors.green;
    if (level >= 20) return Colors.orange;
    return Colors.red;
  }

  // Build the view when reconnecting to a device after hot restart
  Widget _buildReconnectingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Reconnecting to Smarty...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Please wait while we reconnect to your device',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }
}

// Confetti painter for success animation
class ConfettiPainter extends CustomPainter {
  final double progress;
  final Random random = Random();
  
  ConfettiPainter({required this.progress});
  
  @override
  void paint(Canvas canvas, Size size) {
    // Paint for confetti pieces
    final paint = Paint()
      ..style = PaintingStyle.fill;
    
    // Draw multiple confetti pieces
    final confettiCount = 100;
    for (int i = 0; i < confettiCount; i++) {
      // Random position
      final x = random.nextDouble() * size.width;
      final y = size.height * (0.2 + 0.8 * progress) - 
                random.nextDouble() * size.height * progress;
      
      // Random color
      final colors = [
        Colors.red, 
        Colors.blue, 
        Colors.green, 
        Colors.yellow, 
        Colors.purple, 
        Colors.orange,
        Colors.pink,
        Colors.teal
      ];
      paint.color = colors[random.nextInt(colors.length)];
      
      // Random size
      final confettiSize = 5 + random.nextDouble() * 7;
      
      // Draw confetti piece (rectangle or circle)
      if (random.nextBool()) {
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(x, y),
            width: confettiSize,
            height: confettiSize,
          ),
          paint,
        );
      } else {
        canvas.drawCircle(
          Offset(x, y),
          confettiSize / 2,
          paint,
        );
      }
    }
  }
  
  @override
  bool shouldRepaint(ConfettiPainter oldDelegate) => 
      oldDelegate.progress != progress;
}
