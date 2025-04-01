import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home_tab.dart'; 
import 'settings_tab.dart'; 

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MyHomePage(), 
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _currentIndex = 0;

  final List<Widget> _tabs = [
    HomeTab(), 
    SettingsTab(), 
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class ProvisioningTab extends StatefulWidget { 
  const ProvisioningTab({super.key});

  @override
  _ProvisioningTabState createState() => _ProvisioningTabState();
}

class _ProvisioningTabState extends State<ProvisioningTab> {
  static const platform = MethodChannel('esp_provisioning_channel');
  List<String> devices = [];
  String provisioningResult = '';
  String selectedDevice = '';
  String ssid = '';
  String password = '';

  Future<void> _startScanning() async {
    setState(() {
      provisioningResult = 'Scanning for devices...';
      devices = [];
    });

    try {
      final List<dynamic> result = await platform.invokeMethod('startScanning');
      setState(() {
        devices = result.map((item) => item.toString()).toList();
        provisioningResult = devices.isEmpty ? 'No devices found' : '';
      });
    } on PlatformException catch (e) {
      setState(() {
        switch (e.code) {
          case 'DEVICE_NOT_FOUND':
            provisioningResult = e.message ?? 'No devices found';
            break;
          default:
            provisioningResult = 'Error: ${e.message}';
        }
      });
    }
  }

  Future<void> _connectAndProvision() async {
    try {
      final result = await platform.invokeMethod('connectAndProvision', {
        'deviceName': selectedDevice,
        'ssid': ssid,
        'password': password,
      });
      setState(() {
        provisioningResult = result;
      });
    } on PlatformException catch (e) {
      setState(() {
        provisioningResult = 'Failed to provision: ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('ESP Provisioning')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: <Widget>[
            ElevatedButton(
              onPressed: _startScanning,
              child: Text('Look for Smarty'),
            ),
            if (devices.isNotEmpty)
              DropdownButton<String>(
                value: selectedDevice.isNotEmpty? selectedDevice : null,
                items: devices.map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    selectedDevice = newValue!;
                  });
                },
                hint: Text('Select Device'),
              ),
            if (selectedDevice.isNotEmpty)
              TextField(
                onChanged: (value) => ssid = value,
                decoration: InputDecoration(labelText: 'WiFi SSID'),
              ),
            if (selectedDevice.isNotEmpty)
              TextField(
                onChanged: (value) => password = value,
                obscureText: true,
                decoration: InputDecoration(labelText: 'WiFi Password'),
              ),
            if (selectedDevice.isNotEmpty)
              ElevatedButton(
                onPressed: _connectAndProvision,
                child: Text('Connect and Provision'),
              ),
            Text(provisioningResult),
          ],
        ),
      ),
    );
  }
}
