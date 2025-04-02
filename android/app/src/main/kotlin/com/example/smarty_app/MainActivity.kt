package com.example.smarty_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.espressif.provisioning.ESPProvisionManager
import com.espressif.provisioning.ESPDevice
import com.espressif.provisioning.listeners.BleScanListener
import com.espressif.provisioning.listeners.ProvisionListener
import com.espressif.provisioning.listeners.WiFiScanListener
import com.espressif.provisioning.ESPConstants
import java.util.ArrayList

class MainActivity : FlutterActivity() {
    private val CHANNEL = "esp_provisioning_channel"
    private lateinit var espProvisionManager: ESPProvisionManager
    private val devices: MutableList<ESPDevice> = ArrayList()
    private var selectedDevice: ESPDevice? = null

    override fun configureFlutterEngine(flutterEngine: FlutterPlugin.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize ESPProvisionManager
        espProvisionManager = ESPProvisionManager.getInstance(applicationContext)

        // Set up the method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScanning" -> startScanning(result)
                "connectToDevice" -> connectToDevice(call, result)
                "scanWifiNetworks" -> scanWifiNetworks(result)
                "connectAndProvision" -> connectAndProvision(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun startScanning(result: MethodChannel.Result) {
        devices.clear()

        // Retry mechanism similar to iOS
        fun attemptScan(retryCount: Int = 3) {
            espProvisionManager.searchBleEspDevices("Smarty", object : BleScanListener {
                override fun onPeripheralFound(device: BluetoothDevice?) {
                    // Not used in this context
                }

                override fun onFailure(exception: Exception?) {
                    if (retryCount > 0) {
                        // Retry after 1 second
                        Handler(Looper.getMainLooper()).postDelayed({
                            attemptScan(retryCount - 1)
                        }, 1000)
                    } else {
                        result.error(
                            "DEVICE_NOT_FOUND",
                            "No Smarty devices found. Please ensure your device is powered on, in range, and in provisioning mode.",
                            null
                        )
                    }
                }

                override fun onPeripheralNotFound(exception: Exception?) {
                    onFailure(exception)
                }

                override fun scanCompleted(bleDevices: ArrayList<BluetoothDevice>?) {
                    if (bleDevices.isNullOrEmpty()) {
                        onFailure(null)
                        return
                    }

                    // Convert BluetoothDevices to ESPDevices
                    val deviceNames = mutableListOf<String>()
                    for (bleDevice in bleDevices) {
                        val espDevice = espProvisionManager.createESPDevice(
                            ESPConstants.TransportType.TRANSPORT_BLE,
                            ESPConstants.SecurityType.SECURITY_1,
                            bleDevice,
                            "abcd1234", // Proof of Possession (PoP)
                            null // Username (for Security 2)
                        )
                        devices.add(espDevice)
                        deviceNames.add(espDevice.deviceName)
                    }
                    result.success(deviceNames)
                }
            })
        }

        // Check Bluetooth and location permissions before scanning
        if (checkPermissions()) {
            attemptScan()
        } else {
            result.error("PERMISSION_DENIED", "Bluetooth and location permissions are required.", null)
        }
    }

    private fun connectToDevice(call: MethodCall, result: MethodChannel.Result) {
        val deviceName = call.argument<String>("deviceName")
        if (deviceName == null) {
            result.error("INVALID_ARGUMENTS", "Missing deviceName argument", null)
            return
        }

        val device = devices.find { it.deviceName == deviceName }
        if (device == null) {
            result.error("INVALID_ARGUMENTS", "Device not found: $deviceName", null)
            return
        }

        selectedDevice = device

        // Timeout mechanism
        var resultSent = false
        Handler(Looper.getMainLooper()).postDelayed({
            if (!resultSent) {
                resultSent = true
                result.error("CONNECTION_TIMEOUT", "Connection timed out after 10 seconds", null)
            }
        }, 10000)

        // Connect to the device
        device.connectToDevice()
        device.setConnectionListener { connectionStatus ->
            if (resultSent) return@setConnectionListener
            resultSent = true

            when (connectionStatus) {
                ESPConstants.ConnectionStatus.CONNECTED -> result.success("CONNECTED")
                ESPConstants.ConnectionStatus.FAILED_TO_CONNECT -> result.error(
                    "CONNECTION_FAILED",
                    "Failed to connect to device",
                    null
                )
                ESPConstants.ConnectionStatus.DISCONNECTED -> result.error(
                    "DEVICE_DISCONNECTED",
                    "Device disconnected",
                    null
                )
                else -> result.error("UNKNOWN_STATUS", "Unknown connection status", null)
            }
        }
    }

    private fun scanWifiNetworks(result: MethodChannel.Result) {
        val device = selectedDevice
        if (device == null) {
            result.error("NO_DEVICE_CONNECTED", "No device connected", null)
            return
        }

        // Timeout mechanism
        var resultSent = false
        Handler(Looper.getMainLooper()).postDelayed({
            if (!resultSent) {
                resultSent = true
                result.error("WIFI_SCAN_TIMEOUT", "WiFi scan timed out after 10 seconds", null)
            }
        }, 10000)

        // Scan for Wi-Fi networks
        device.scanNetworks(object : WiFiScanListener {
            override fun onWifiListReceived(wifiList: ArrayList<com.espressif.provisioning.WiFiAccessPoint>?) {
                if (resultSent) return
                resultSent = true

                if (wifiList == null) {
                    result.success(emptyList<String>())
                    return
                }

                val wifiNetworks = wifiList.map { it.wifiName }
                result.success(wifiNetworks)
            }

            override fun onWiFiScanFailed(e: Exception?) {
                if (resultSent) return
                resultSent = true
                result.error("WIFI_SCAN_ERROR", e?.message ?: "Unknown error", null)
            }
        })
    }

    private fun connectAndProvision(call: MethodCall, result: MethodChannel.Result) {
        val ssid = call.argument<String>("ssid")
        val password = call.argument<String>("password")
        val device = selectedDevice

        if (ssid == null || password == null || device == null) {
            result.error("INVALID_ARGUMENTS", "Invalid arguments or no device connected", null)
            return
        }

        // Timeout mechanism
        var resultSent = false
        Handler(Looper.getMainLooper()).postDelayed({
            if (!resultSent) {
                resultSent = true
                result.error("PROVISION_TIMEOUT", "Provisioning timed out after 30 seconds", null)
            }
        }, 30000)

        // Provision the device
        device.provision(ssid, password, object : ProvisionListener {
            override fun onSuccess() {
                if (resultSent) return
                resultSent = true
                result.success("SUCCESS")
            }

            override fun onFailure(e: Exception?) {
                if (resultSent) return
                resultSent = true
                result.error("PROVISION_ERROR", e?.message ?: "Provisioning failed", null)
            }
        })
    }

    private fun checkPermissions(): Boolean {
        // Simplified permission check (you should implement proper permission handling)
        // For brevity, assuming permissions are granted
        // In a real app, use ActivityCompat.requestPermissions to request permissions
        return true
    }
}
