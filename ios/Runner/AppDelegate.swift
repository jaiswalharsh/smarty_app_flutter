import UIKit
import Flutter
import ESPProvision

@main
@objc class AppDelegate: FlutterAppDelegate, ESPDeviceConnectionDelegate {
    private var espManager: ESPProvisionManager!
    private var devices: [ESPDevice] = []
    private var selectedDevice: ESPDevice?
    private var pendingWifiScanResult: FlutterResult?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        print("🚀 AppDelegate: Application did finish launching")

        let controller: FlutterViewController = self.window?.rootViewController as! FlutterViewController
        let espProvisioningChannel = FlutterMethodChannel(name: "esp_provisioning_channel", binaryMessenger: controller.binaryMessenger)

        // Initialize ESP Provision Manager
        espManager = ESPProvisionManager.shared
        print("🚀 AppDelegate: ESP Provision Manager initialized")

        espProvisioningChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            print("🚀 AppDelegate: Received method call: \(call.method)")
            
            switch call.method {
            case "startScanning":
                self.startScanning(result: result)
            case "connectAndProvision":
                self.connectAndProvision(call: call, result: result)
            case "connectToDevice":
                self.connectToDevice(call: call, result: result)
            case "scanWifiNetworks":
                self.scanWifiNetworks(call: call, result: result)
            default:
                print("❌ AppDelegate: Method not implemented: \(call.method)")
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func startScanning(result: @escaping FlutterResult) {
        devices.removeAll()
        
        // Start scanning with retry mechanism
        func attemptScan(retryCount: Int = 3) {
            espManager.searchESPDevices(devicePrefix: "Smarty", transport: .ble, security: .secure) { devices, error in
                if let devices = devices, !devices.isEmpty {
                    self.devices = devices
                    let deviceNames = devices.map { $0.name }
                    result(deviceNames)
                } else if let error = error as? ESPDeviceCSSError, error.code == 6 {
                    if retryCount > 0 {
                        // Wait for 1 second before retrying
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            attemptScan(retryCount: retryCount - 1)
                        }
                    } else {
                        result(FlutterError(code: "DEVICE_NOT_FOUND",
                                          message: "No Smarty devices found. Please ensure your device is powered on, in range, and in provisioning mode.",
                                          details: nil))
                    }
                } else {
                    result(FlutterError(code: "SCAN_ERROR",
                                      message: error?.localizedDescription ?? "Unknown error occurred",
                                      details: nil))
                }
            }
        }
        
        attemptScan()
    }

    func connectToDevice(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🔵 AppDelegate: connectToDevice method called")
        
        guard let args = call.arguments as? [String: Any] else {
            print("❌ AppDelegate: Invalid arguments format")
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments format", details: nil))
            return
        }
        
        guard let deviceName = args["deviceName"] as? String else {
            print("❌ AppDelegate: Missing deviceName argument")
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing deviceName argument", details: nil))
            return
        }
        
        print("🔵 AppDelegate: Looking for device with name: \(deviceName)")
        print("🔵 AppDelegate: Available devices: \(devices.map { $0.name })")
        
        guard let device = devices.first(where: { $0.name == deviceName }) else {
            print("❌ AppDelegate: Device not found: \(deviceName)")
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Device not found: \(deviceName)", details: nil))
            return
        }
        
        print("🔵 AppDelegate: Found device: \(device.name)")
        
        // Store the selected device
        self.selectedDevice = device
        
        // Create a flag to track if we've already sent a result
        var resultSent = false
        
        // Create a timer that will trigger if connection takes too long
        let timeoutTimer = DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if !resultSent {
                print("⏰ AppDelegate: Connection attempt timed out")
                resultSent = true
                result(FlutterError(code: "CONNECTION_TIMEOUT", message: "Connection timed out after 10 seconds", details: nil))
            }
        }
        
        // Connect to the device
        print("🔵 AppDelegate: Connecting to device: \(device.name)")
        device.connect(delegate: self) { status in
            resultSent = true
            
            switch status {
            case .connected:
                print("✅ AppDelegate: Successfully connected to: \(deviceName)")
                result("CONNECTED")
            case .failedToConnect:
                print("❌ AppDelegate: Failed to connect to: \(deviceName)")
                result(FlutterError(code: "CONNECTION_FAILED", message: "Failed to connect to device", details: nil))
            case .disconnected:
                print("❌ AppDelegate: Device disconnected: \(deviceName)")
                result(FlutterError(code: "DEVICE_DISCONNECTED", message: "Device disconnected", details: nil))
            @unknown default:
                print("❌ AppDelegate: Unknown connection status: \(status)")
                result(FlutterError(code: "UNKNOWN_STATUS", message: "Unknown connection status", details: nil))
            }
        }
    }
    
    func scanWifiNetworks(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🔵 AppDelegate: scanWifiNetworks called")
        
        // Check if we have a selected device
        guard let selectedDevice = self.selectedDevice else {
            print("❌ AppDelegate: No device connected for WiFi scan")
            result(FlutterError(code: "NO_DEVICE_CONNECTED", message: "No device connected", details: nil))
            return
        }
        
        print("🔵 AppDelegate: Scanning for WiFi networks with device: \(selectedDevice.name)")
        
        // Create a flag to track if we've already sent a result
        var resultSent = false
        
        // Create a timer that will trigger if scanning takes too long
        let timeoutTimer = DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if !resultSent {
                print("⏰ AppDelegate: WiFi scan timed out")
                resultSent = true
                result(FlutterError(code: "WIFI_SCAN_TIMEOUT", message: "WiFi scan timed out after 10 seconds", details: nil))
            }
        }
        
        // Add a delay before sending the WiFi scan command
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("🔵 AppDelegate: Waiting for 2 seconds before sending WiFi scan command")
            
            // Use the actual ESP SDK method to scan for WiFi networks
            print("🔵 AppDelegate: Calling scanWifiList on device")
            selectedDevice.scanWifiList { wifiList, error in
                // Cancel the timeout since we got a response
                resultSent = true
                
                if let error = error {
                    // Detailed error logging for debugging
                    print("❌ AppDelegate: WiFi scan error: \(error.localizedDescription)")
                    print("❌ AppDelegate: Error code: \(error.code)")
                    
                    // Check if it's an ESPWiFiScanError
                    if let wifiScanError = error as? ESPWiFiScanError {
                        print("❌ AppDelegate: ESPWiFiScanError code: \(wifiScanError.code)")
                        
                        // Log different error cases
                        switch wifiScanError.code {
                        case 1:
                            print("❌ AppDelegate: ESPWiFiScanError: Device not connected")
                        case 2:
                            print("❌ AppDelegate: ESPWiFiScanError: Command execution failed")
                        case 3:
                            print("❌ AppDelegate: ESPWiFiScanError: Response parsing error")
                        default:
                            print("❌ AppDelegate: ESPWiFiScanError: Unknown error code")
                        }
                    }
                    
                    // Check if it's an NSError with userInfo
                    if let nsError = error as NSError? {
                        print("❌ AppDelegate: NSError userInfo: \(nsError.userInfo)")
                    }
                    
                    result(FlutterError(code: "WIFI_SCAN_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                
                guard let wifiList = wifiList else {
                    print("❌ AppDelegate: WiFi list is nil")
                    result([])
                    return
                }
                
                print("✅ AppDelegate: Found \(wifiList.count) WiFi networks")
                
                // Extract the SSID from each WiFi network
                let wifiNetworks = wifiList.compactMap { $0.ssid }
                
                // Log the found networks
                for (index, network) in wifiNetworks.enumerated() {
                    print("📶 AppDelegate: WiFi network \(index + 1): \(network)")
                }
                
                result(wifiNetworks)
            }
        }
    }
    
    func connectAndProvision(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🔵 AppDelegate: connectAndProvision called")
        
        guard let args = call.arguments as? [String: Any],
              let ssid = args["ssid"] as? String,
              let password = args["password"] as? String,
              let selectedDevice = self.selectedDevice else {
            print("❌ AppDelegate: Invalid arguments or no device connected for provisioning")
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments or no device connected", details: nil))
            return
        }
        
        print("🔵 AppDelegate: Provisioning device with SSID: \(ssid), Password: [HIDDEN]")
        
        // Create a flag to track if we've already sent a result
        var resultSent = false
        
        // Create a timer that will trigger if provisioning takes too long
        let timeoutTimer = DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            if !resultSent {
                print("⏰ AppDelegate: Provisioning timed out")
                resultSent = true
                result(FlutterError(code: "PROVISION_TIMEOUT", message: "Provisioning timed out after 30 seconds", details: nil))
            }
        }

        selectedDevice.provision(ssid: ssid, passPhrase: password) { provisionStatus in
            // Cancel the timeout since we got a response
            resultSent = true
            
            // Log the provision status for debugging
            print("🔵 AppDelegate: Provision status: \(provisionStatus)")
            
            // Handle different provision statuses
            switch provisionStatus {
            case .success:
                print("✅ AppDelegate: Provisioning successful")
                result("SUCCESS")
            case .failure:
                print("❌ AppDelegate: Provisioning failed")
                result(FlutterError(code: "PROVISION_ERROR", message: "Provisioning failed", details: nil))
            default:
                // Check if the status is "configApplied" (as a string)
                let statusString = String(describing: provisionStatus)
                if statusString == "configApplied" {
                    print("✅ AppDelegate: Provisioning successful (configApplied)")
                    result("SUCCESS")
                } else {
                    print("❌ AppDelegate: Provisioning failed with unknown status: \(statusString)")
                    result(FlutterError(code: "PROVISION_ERROR", message: "Provisioning failed with unknown error", details: nil))
                }
            }
        }
    }

    // MARK: - ESPDeviceConnectionDelegate Methods
    
    func getProofOfPossesion(forDevice device: ESPDevice, completionHandler: @escaping (String) -> Void) {
        print("🔵 AppDelegate: getProofOfPossesion called for device: \(device.name)")
        // Return the proof of possession (PoP) for the device
        // This is typically a code that is printed on the device or provided in the documentation
        completionHandler("abcd1234")
    }
    
    func getUsername(forDevice device: ESPDevice, completionHandler: @escaping (String?) -> Void) {
        print("🔵 AppDelegate: getUsername called for device: \(device.name)")
        // Return the username for the device (for security version 2)
        // This is typically a username that is printed on the device or provided in the documentation
        completionHandler("user")
    }

    func listAvailableWiFiNetworks() {
        // Here we would ideally use the ESP device to scan for WiFi networks
        // For demonstration purposes, we'll show a list of networks
        DispatchQueue.main.async {
            let wifiNetworks = ["Network 1", "Network 2", "Network 3"]
            let alertController = UIAlertController(title: "Select WiFi Network", message: nil, preferredStyle: .actionSheet)
            for network in wifiNetworks {
                let action = UIAlertAction(title: network, style: .default) { _ in
                    self.promptForPassword(network: network)
                }
                alertController.addAction(action)
            }
            alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            UIApplication.shared.windows.first?.rootViewController?.present(alertController, animated: true)
        }
    }

    func promptForPassword(network: String) {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: "Enter Password for \(network)", message: nil, preferredStyle: .alert)
            alertController.addTextField { textField in
                textField.placeholder = "Password"
                textField.isSecureTextEntry = true
            }
            let confirmAction = UIAlertAction(title: "Connect", style: .default) { _ in
                if let password = alertController.textFields?.first?.text {
                    self.sendWiFiSSIDAndPassword(ssid: network, password: password)
                }
            }
            alertController.addAction(confirmAction)
            alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            UIApplication.shared.windows.first?.rootViewController?.present(alertController, animated: true)
        }
    }

    func sendWiFiSSIDAndPassword(ssid: String, password: String) {
        guard let device = selectedDevice else { return }
        
        device.connect { status in
            if case .connected = status {
                device.provision(ssid: ssid, passPhrase: password) { provisionStatus in
                    DispatchQueue.main.async {
                        let title: String
                        let message: String
                        
                        switch provisionStatus {
                        case .success:
                            title = "Success"
                            message = "WiFi provisioning successful"
                        default:
                            title = "Error"
                            message = "WiFi provisioning failed"
                        }
                        
                        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
                        alertController.addAction(UIAlertAction(title: "OK", style: .default))
                        UIApplication.shared.windows.first?.rootViewController?.present(alertController, animated: true)
                    }
                }
            }
        }
    }
}
