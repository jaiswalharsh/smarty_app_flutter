import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService {
  // BLE UUIDs
  static const String smartyServiceUuid = "0000abcd-0000-1000-8000-00805f9b34fb";
  static const String wifiScanUuid = "0000ab01-0000-1000-8000-00805f9b34fb";
  static const String wifiCredsUuid = "0000ab02-0000-1000-8000-00805f9b34fb";
  static const String userDataUuid = "0000ab03-0000-1000-8000-00805f9b34fb";
  static const String statusUpdateUuid = "0000ab04-0000-1000-8000-00805f9b34fb";

  // Current adapter state. Waits up to 3 seconds for CoreBluetooth to leave
  // the "unknown" state, avoiding false negatives on cold launch. If it still
  // hasn't decided, returns [BluetoothAdapterState.unknown] — callers must
  // treat that as "not known yet, retry", NEVER as "Bluetooth is off" (and
  // certainly never as "the toy is off").
  static Future<BluetoothAdapterState> getBluetoothState() async {
    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.unknown) return state;

      // CoreBluetooth hasn't initialized yet — wait for a definitive state
      return await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 3),
              onTimeout: () => BluetoothAdapterState.unknown);
    } catch (e) {
      debugPrint("⚠️ BleService: couldn't read adapter state: $e");
      return BluetoothAdapterState.unknown;
    }
  }

  static Future<void>? _configured;

  /// Sets FlutterBluePlus's options once per launch; never throws. main()
  /// awaits it before runApp, because the options must be set before any
  /// other FlutterBluePlus call: on iOS the plugin creates its
  /// CBCentralManager on the first call and reads them only then.
  ///
  /// `showPowerAlert`: when Bluetooth is off as the manager is created, iOS
  /// shows its own "Turn On Bluetooth to Allow …" alert, whose Settings button
  /// opens Settings → Bluetooth. That alert is the only sanctioned way there —
  /// an app may only open its own page in Settings, which is all our "Open
  /// Settings" buttons can do. It is the plugin's default today; set here so
  /// it can't quietly change. No effect on Android.
  static Future<void> configureBeforeFirstUse() =>
      _configured ??= _setOptions();

  static Future<void> _setOptions() async {
    try {
      await FlutterBluePlus.setOptions(showPowerAlert: true);
    } catch (e) {
      debugPrint("⚠️ BleService: couldn't set Bluetooth options: $e");
    }
  }

  // Android: the Bluetooth settings page. iOS allows no link to Settings →
  // Bluetooth, so this opens the app's own page in Settings — the copy around
  // every such button says so (setup_steps.dart).
  static Future<void> _openBluetoothSettings() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
    } catch (e) {
      debugPrint('❌ Error opening Bluetooth settings: $e');
    }
  }
  
  // Public method to open Bluetooth settings
  static Future<void> openBluetoothSettings() async {
    await _openBluetoothSettings();
  }

  // Open this app's own settings page, where the user can grant the Bluetooth
  // permission they previously denied.
  static Future<void> openAppPermissionSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.settings);

  // Find the Smarty service (0xABCD) in a list of services. Guid equality
  // normalizes 16-bit and 128-bit forms case-insensitively, so this is an
  // exact match — not a substring match that any UUID containing "abcd" hits.
  static BluetoothService? findSmartyService(List<BluetoothService> services) {
    final target = Guid(smartyServiceUuid);
    for (BluetoothService service in services) {
      if (service.uuid == target) {
        return service;
      }
    }
    return null;
  }

  // Find a characteristic by exact UUID in a service. [uuid] may be the 16-bit
  // short form ("ab04") or the full 128-bit string.
  static BluetoothCharacteristic? findCharacteristic(
    BluetoothService service,
    String uuid,
  ) {
    final Guid target;
    try {
      target = Guid(uuid);
    } on FormatException {
      debugPrint("❌ BleService: invalid characteristic UUID '$uuid'");
      return null;
    }
    for (BluetoothCharacteristic characteristic in service.characteristics) {
      if (characteristic.uuid == target) {
        return characteristic;
      }
    }
    return null;
  }
}
