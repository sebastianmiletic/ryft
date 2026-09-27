import AppKit
import Combine
import CoreAudio
import CoreLocation
import CoreWLAN
import IOKit.ps
import ApplicationServices

struct WiFiNetworkInfo: Identifiable, Hashable {
    let id: String
    let ssid: String
    let signal: Int
    let secure: Bool
    let known: Bool
    let network: CWNetwork
}

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

final class SystemControlService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var wifiEnabled = false
    @Published var connectedSSID = "Not connected"
    @Published var wifiNetworks: [WiFiNetworkInfo] = []
    @Published var scanningWiFi = false
    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var defaultAudioDevice: AudioDeviceID = 0
    @Published var outputVolume: Double = 50
    @Published var lowPowerMode = false
    @Published var highPowerMode = false
    @Published private(set) var supportsHighPowerMode = false
    @Published var batteryPercent = "--"
    @Published var batteryLevel = -1
    @Published var batteryCharging = false
    @Published var operationMessage = ""

    // Core Location must be created after NSApplication has finished launching.
    // Constructing it during SwiftUI's early model initialization gives
    // locationd an empty bundle identity, so macOS cannot persist its decision.
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = true
        return manager
    }()
    private var levelTimer: Timer?
    private var wifiConnectionAttempt = UUID()
    private var powerTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        refreshPowerCapabilities()
        refreshAll()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.refreshOutputLevel() }
        powerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPowerState() }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SystemControlService>.fromOpaque(context).takeUnretainedValue().refreshPowerState()
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.refreshPowerState() })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshAll() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.locationManager.authorizationStatus == .authorized || self.locationManager.authorizationStatus == .authorizedAlways else { return }
            self.scanWiFi()
        }
    }
    deinit {
        levelTimer?.invalidate(); powerTimer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func refreshAll() {
        refreshWiFiState(); refreshAudioDevices(); refreshPowerState()
    }

    func prepareWiFiMenu() {
        operationMessage = ""
        refreshWiFiState()
        if wifiNetworks.isEmpty { requestWiFiAccessAndScan() }
    }

    func prepareSoundMenu() {
        operationMessage = ""
        refreshAudioDevices()
    }

    func requestWiFiAccessAndScan() {
        switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways:
            // CoreWLAN can continue returning redacted/empty scan results until
            // locationd has delivered at least one update to this process.
            locationManager.startUpdatingLocation()
            scanWiFi()
        case .notDetermined:
            // Retain and actively use the same manager through authorization.
            // This prevents System Settings from treating the request as an
            // abandoned transient client and immediately reverting its toggle.
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
        case .denied, .restricted: operationMessage = "Allow Location in Privacy & Security to list nearby Wi-Fi networks."
        @unknown default: operationMessage = "Nearby Wi-Fi networks are unavailable."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            scanWiFi()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { manager.stopUpdatingLocation() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        scanWiFi()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code != .denied { operationMessage = "Location check: \(error.localizedDescription)" }
    }

    func refreshWiFiState() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        wifiEnabled = interface.powerOn()
        connectedSSID = interface.ssid() ?? "Not connected"
    }

    func setWiFiEnabled(_ enabled: Bool) {
        guard let interface = CWWiFiClient.shared().interface() else { operationMessage = "Wi-Fi interface is unavailable."; return }
        do {
            try interface.setPower(enabled)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshWiFiState(); if enabled { self.scanWiFi() } }
        } catch {
            runNetworkSetup(["-setairportpower", interface.interfaceName ?? "en0", enabled ? "on" : "off"]) { success, message in
                self.refreshWiFiState()
                self.operationMessage = success ? (enabled ? "Wi-Fi enabled" : "Wi-Fi disabled") : "Wi-Fi: \(message)"
                if success && enabled { self.scanWiFi() }
            }
        }
    }

    func scanWiFi() { scanWiFi(attempt: 0) }

    private func scanWiFi(attempt: Int) {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            wifiNetworks = []; scanningWiFi = false; operationMessage = wifiEnabled ? "Wi-Fi interface is unavailable." : "Wi-Fi is off."
            return
        }
        scanningWiFi = true
        if attempt == 0 { operationMessage = "Scanning nearby networks…" }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try interface.scanForNetworks(withSSID: nil)
                let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
                let knownSSIDs = Set(profiles.compactMap(\.ssid))
                let mapped = results.compactMap { network -> WiFiNetworkInfo? in
                    guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
                    return WiFiNetworkInfo(id: "\(ssid)-\(network.bssid ?? "")", ssid: ssid, signal: network.rssiValue, secure: !network.supportsSecurity(.none), known: knownSSIDs.contains(ssid), network: network)
                }.sorted { $0.signal > $1.signal }
                var seen = Set<String>()
                let unique = mapped.filter { seen.insert($0.ssid).inserted }
                DispatchQueue.main.async {
                    if unique.isEmpty, attempt < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt + 1)) { self.scanWiFi(attempt: attempt + 1) }
                    } else {
                        self.wifiNetworks = unique
                        self.scanningWiFi = false
                        self.operationMessage = unique.isEmpty ? "No nearby networks found. Toggle Location access off and on, then refresh." : ""
                        self.refreshWiFiState()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if attempt < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt + 1)) { self.scanWiFi(attempt: attempt + 1) }
                    } else {
                        self.operationMessage = "Wi-Fi scan: \(error.localizedDescription)"
                        self.scanningWiFi = false
                    }
                }
            }
        }
    }

    func connect(to info: WiFiNetworkInfo, password: String = "") {
        guard let interface = CWWiFiClient.shared().interface() else { operationMessage = "Wi-Fi interface is unavailable."; return }
        let suppliedPassword = info.secure && !info.known ? password : ""
        let attempt = UUID(); wifiConnectionAttempt = attempt
        operationMessage = "Connecting to \(info.ssid)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do { try interface.associate(to: info.network, password: suppliedPassword.isEmpty ? nil : suppliedPassword) }
            catch { /* networksetup below can use the saved system profile */ }
            DispatchQueue.main.async { self.verifyWiFiConnection(ssid: info.ssid, password: suppliedPassword, attempt: attempt, poll: 0) }
        }
    }

    func connectHiddenNetwork(ssid: String, password: String) {
        let ssid = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, let interface = CWWiFiClient.shared().interface() else { operationMessage = "Enter a network name."; return }
        let attempt = UUID(); wifiConnectionAttempt = attempt
        operationMessage = "Finding \(ssid)…"
        DispatchQueue.global(qos: .userInitiated).async {
            if let network = try? interface.scanForNetworks(withName: ssid).max(by: { $0.rssiValue < $1.rssiValue }) {
                try? interface.associate(to: network, password: password.isEmpty ? nil : password)
            }
            DispatchQueue.main.async { self.verifyWiFiConnection(ssid: ssid, password: password, attempt: attempt, poll: 0) }
        }
    }

    func disconnectWiFi() {
        wifiConnectionAttempt = UUID()
        CWWiFiClient.shared().interface()?.disassociate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.refreshWiFiState(); self.operationMessage = "Disconnected" }
    }

    private func verifyWiFiConnection(ssid: String, password: String, attempt: UUID, poll: Int) {
        guard wifiConnectionAttempt == attempt else { return }
        refreshWiFiState()
        if connectedSSID == ssid {
            operationMessage = "Connected to \(ssid)"
            scanWiFi()
            return
        }
        if poll < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.verifyWiFiConnection(ssid: ssid, password: password, attempt: attempt, poll: poll + 1) }
            return
        }
        guard let interface = CWWiFiClient.shared().interface() else { operationMessage = "Wi-Fi interface is unavailable."; return }
        var arguments = ["-setairportnetwork", interface.interfaceName ?? "en0", ssid]
        if !password.isEmpty { arguments.append(password) }
        runNetworkSetup(arguments) { success, message in
            guard self.wifiConnectionAttempt == attempt else { return }
            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.refreshWiFiState()
                    self.operationMessage = self.connectedSSID == ssid ? "Connected to \(ssid)" : "Could not switch to \(ssid)."
                    if self.connectedSSID == ssid { self.scanWiFi() }
                }
            } else {
                self.operationMessage = "Could not connect: \(message)"
            }
        }
    }

    private func runNetworkSetup(_ arguments: [String], completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = errorPipe
            do {
                try process.run(); process.waitUntilExit()
                let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                DispatchQueue.main.async { completion(process.terminationStatus == 0, message) }
            } catch { DispatchQueue.main.async { completion(false, error.localizedDescription) } }
        }
    }

    func refreshAudioDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        audioDevices = ids.compactMap { id in
            guard deviceHasOutput(id), let name = deviceName(id) else { return nil }
            return AudioDeviceInfo(id: id, name: name)
        }
        var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var current: AudioDeviceID = 0
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &currentSize, &current) == noErr { defaultAudioDevice = current }
        refreshOutputLevel()
    }

    func selectAudioDevice(_ id: AudioDeviceID) {
        var selected = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &selected)
        operationMessage = status == noErr ? "Audio output changed" : "Could not change audio output"
        refreshAudioDevices()
    }

    func refreshOutputLevel() {
        var device = defaultAudioDevice
        if device == 0 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return }
            defaultAudioDevice = device
        }
        var levels: [Float32] = []
        for channel in [AudioObjectPropertyElement(0), 1, 2] {
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            if AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr { levels.append(volume) }
        }
        guard !levels.isEmpty else { return }
        let percent = Double((levels.reduce(0, +) / Float32(levels.count)) * 100)
        if abs(outputVolume - percent) > 0.4 { outputVolume = percent }
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = value
        let script = "set volume output volume \(Int(value))"
        runAppleScript(script)
    }

    func setMuted(_ muted: Bool) { runAppleScript("set volume output muted \(muted ? "true" : "false")") }

    func refreshPowerState() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            lowPowerMode = lowPower
            return
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == (kIOPSInternalBatteryType as String),
                  (description[kIOPSIsPresentKey] as? Bool) != false else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = max((description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100, 1)
            let level = max(0, min(100, Int((current / maximum * 100).rounded())))
            let charging = (description[kIOPSIsChargingKey] as? Bool) == true
            if batteryLevel != level { batteryLevel = level; batteryPercent = "\(level)%" }
            if batteryCharging != charging { batteryCharging = charging }
            if lowPowerMode != lowPower { lowPowerMode = lowPower }
            return
        }
        lowPowerMode = lowPower
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard enabled != lowPowerMode else { return }
        operationMessage = enabled ? "Enabling Low Power Mode…" : "Disabling Low Power Mode…"
        runPasswordlessPowerCommand(["-b", "lowpowermode", enabled ? "1" : "0"]) { [weak self] success in
            guard let self else { return }
            self.refreshPowerState()
            if success && self.lowPowerMode == enabled {
                self.operationMessage = enabled ? "Low Power Mode enabled" : "Normal power mode enabled"
            } else {
                // pmset is root-only on standard macOS. Fall back to pressing
                // Apple's own battery control through Accessibility; this uses
                // Control Center's existing privilege without a password or a
                // System Settings window.
                self.setLowPowerModeThroughBatteryMenu(enabled)
            }
        }
    }

    func setHighPowerMode(_ enabled: Bool) {
        guard supportsHighPowerMode else { return }
        operationMessage = enabled ? "Enabling High Power Mode…" : "Returning to Automatic…"
        runPasswordlessPowerCommand(["-a", "highpowermode", enabled ? "1" : "0"]) { [weak self] success in
            guard let self else { return }
            self.highPowerMode = success && enabled
            if success { self.operationMessage = enabled ? "High Power Mode enabled" : "Automatic power mode enabled" }
            else { self.setHighPowerModeThroughBatteryMenu(enabled) }
        }
    }

    private func refreshPowerCapabilities() {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); task.arguments = ["-g", "custom"]; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; supportsHighPowerMode = output.contains("highpowermode"); highPowerMode = output.range(of: #"highpowermode\s+1"#, options: .regularExpression) != nil } catch { }
    }

    private func runPasswordlessPowerCommand(_ arguments: [String], completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do { try task.run(); task.waitUntilExit(); DispatchQueue.main.async { completion(task.terminationStatus == 0) } }
            catch { DispatchQueue.main.async { completion(false) } }
        }
    }

    private func setHighPowerModeThroughBatteryMenu(_ enabled: Bool) {
        guard AXIsProcessTrusted() else { operationMessage = "Accessibility is required to change power mode from Ryft."; return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.controlcenter" || $0.bundleIdentifier == "com.apple.systemuiserver" }
        let roots = apps.map { AXUIElementCreateApplication($0.processIdentifier) }
        let batteryItem = roots.flatMap { accessibilityDescendants(of: $0) }.first { element in
            let role: String = axAttribute(element, kAXRoleAttribute as CFString) ?? ""
            return role == (kAXMenuBarItemRole as String) && axText(element).contains("battery")
        }
        guard let batteryItem, AXUIElementPerformAction(batteryItem, kAXPressAction as CFString) == .success else { operationMessage = "Apple's battery control is unavailable."; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.chooseHighPowerMode(enabled, roots: roots, attempt: 0) }
    }

    private func chooseHighPowerMode(_ enabled: Bool, roots: [AXUIElement], attempt: Int) {
        refreshPowerCapabilities()
        if highPowerMode == enabled { operationMessage = enabled ? "High Power Mode enabled" : "Automatic power mode enabled"; return }
        let elements = roots.flatMap { accessibilityDescendants(of: $0) }
        let terms = enabled ? ["high power"] : ["automatic", "normal"]
        let choice = elements.first { element in
            let role: String = axAttribute(element, kAXRoleAttribute as CFString) ?? ""
            return (role == (kAXMenuItemRole as String) || role == (kAXButtonRole as String) || role == (kAXPopUpButtonRole as String)) && terms.contains(where: { axText(element).contains($0) })
        }
        if let choice { _ = AXUIElementPerformAction(choice, kAXPressAction as CFString) }
        guard attempt < 5 else { operationMessage = "macOS did not expose an actionable High Power Mode control."; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.chooseHighPowerMode(enabled, roots: roots, attempt: attempt + 1) }
    }

    private func setLowPowerModeThroughBatteryMenu(_ enabled: Bool) {
        guard AXIsProcessTrusted() else {
            operationMessage = "Accessibility is required to change power mode from Ryft."
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.controlcenter" || $0.bundleIdentifier == "com.apple.systemuiserver"
        }
        let roots = apps.map { AXUIElementCreateApplication($0.processIdentifier) }
        let allElements = roots.flatMap { accessibilityDescendants(of: $0) }
        let batteryItem = allElements.first { element in
            let role: String = axAttribute(element, kAXRoleAttribute as CFString) ?? ""
            guard role == (kAXMenuBarItemRole as String) else { return false }
            return axText(element).contains("battery")
        }
        guard let batteryItem, AXUIElementPerformAction(batteryItem, kAXPressAction as CFString) == .success else {
            operationMessage = "Apple's battery control is unavailable."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.chooseLowPowerMode(enabled, roots: roots, attempt: 0)
        }
    }

    private func chooseLowPowerMode(_ enabled: Bool, roots: [AXUIElement], attempt: Int) {
        refreshPowerState()
        if lowPowerMode == enabled {
            operationMessage = enabled ? "Low Power Mode enabled" : "Normal power mode enabled"
            return
        }
        let elements = roots.flatMap { accessibilityDescendants(of: $0) }
        let actionable = elements.filter { element in
            let role: String = axAttribute(element, kAXRoleAttribute as CFString) ?? ""
            return role == (kAXMenuItemRole as String) || role == (kAXCheckBoxRole as String) || role == (kAXButtonRole as String) || role == (kAXPopUpButtonRole as String)
        }
        if attempt == 0, let lowPower = actionable.first(where: { axText($0).contains("low power mode") }) {
            _ = AXUIElementPerformAction(lowPower, kAXPressAction as CFString)
        } else {
            let terms = enabled ? ["always"] : ["never", "normal", "automatic", "off"]
            if let choice = actionable.first(where: { item in terms.contains(where: { axText(item).contains($0) }) }) {
                _ = AXUIElementPerformAction(choice, kAXPressAction as CFString)
            }
        }
        guard attempt < 5 else {
            refreshPowerState()
            operationMessage = lowPowerMode == enabled
                ? (enabled ? "Low Power Mode enabled" : "Normal power mode enabled")
                : "macOS did not expose an actionable battery power-mode control."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.chooseLowPowerMode(enabled, roots: roots, attempt: attempt + 1)
        }
    }

    private func axText(_ element: AXUIElement) -> String {
        let title: String = axAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let description: String = axAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let value: String = axAttribute(element, kAXValueAttribute as CFString) ?? ""
        return "\(title) \(description) \(value)".lowercased()
    }

    private func accessibilityDescendants(of root: AXUIElement, limit: Int = 1200) -> [AXUIElement] {
        var result: [AXUIElement] = []; var queue: [AXUIElement] = [root]; var index = 0
        while index < queue.count, result.count < limit {
            let element = queue[index]; index += 1; result.append(element)
            if let children: [AXUIElement] = axAttribute(element, kAXChildrenAttribute as CFString) { queue.append(contentsOf: children) }
        }
        return result
    }

    private func axAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?; NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Action failed"
            operationMessage = message.localizedCaseInsensitiveContains("cancel") ? "" : message
        }
    }
    private func runProcess(_ path: String, _ arguments: [String], completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; do { try process.run(); process.waitUntilExit(); completion(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "") } catch { completion("") } }
    }
    private func deviceHasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain); var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }
}
