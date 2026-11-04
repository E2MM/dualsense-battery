// DualSense Battery
//
// Icona nella barra dei menu che mostra la batteria del DualSense leggendola
// direttamente dai report HID del controller, invece che dal valore in cache
// che usano il widget Batterie e il pannello Bluetooth di macOS.
//
// Formato dei report: drivers/hid/hid-playstation.c nel kernel Linux.
// Avvio con log diagnostici: "/Applications/DualSense Battery.app/Contents/MacOS/DualSenseBattery" --debug

import AppKit
import IOKit.hid
import ServiceManagement
import UserNotifications

enum Debug {
    static let enabled = CommandLine.arguments.contains("--debug")

    static func log(_ message: @autoclosure () -> String) {
        if enabled { print("[DualSenseBattery] \(message())") }
    }
}

// MARK: - Protocollo DualSense

enum DualSense {
    static let vendorID = 0x054C
    static let productIDs = [0x0CE6, 0x0DF2]       // DualSense, DualSense Edge

    static let usbReportID: UInt32 = 0x01          // 64 byte via USB (10 byte nel Bluetooth "semplice")
    static let bluetoothReportID: UInt32 = 0x31    // 78 byte via Bluetooth
    static let calibrationReportID = 0x05          // leggerlo attiva i report Bluetooth completi

    /// Lunghezza del blocco dati comune a USB e Bluetooth.
    private static let payloadLength = 63
    /// Offset del byte di stato nel blocco comune.
    private static let statusOffset = 52

    struct Battery: Equatable {
        enum State { case discharging, charging, full, error }
        var percent: Int
        var state: State
    }

    /// Estrae il byte di stato da un report di input, se il report contiene la batteria.
    static func statusByte(reportID: UInt32, report: UnsafePointer<UInt8>, length: Int) -> UInt8? {
        let payloadStart: Int
        switch reportID {
        case usbReportID:
            // [ID][dati 63]: con o senza byte di ID davanti
            payloadStart = length >= payloadLength + 1 ? 1 : 0
        case bluetoothReportID:
            // [ID][tag][dati 63][…][CRC32]
            payloadStart = length >= 78 ? 2 : 1
        default:
            return nil
        }
        // Il report Bluetooth "semplice" (10 byte) non contiene la batteria.
        guard length >= payloadStart + payloadLength else { return nil }
        return report[payloadStart + statusOffset]
    }

    /// Nibble basso: livello 0…10 (passi da 10%). Nibble alto: stato di carica.
    static func decode(_ status: UInt8) -> Battery {
        let level = Int(status & 0x0F)
        switch status >> 4 {
        case 0x0: return Battery(percent: min(level * 10 + 5, 100), state: .discharging)
        case 0x1: return Battery(percent: min(level * 10 + 5, 100), state: .charging)
        case 0x2: return Battery(percent: 100, state: .full)
        default:  return Battery(percent: 0, state: .error)
        }
    }
}

// MARK: - Controller collegato

@MainActor
final class Pad {
    let device: IOHIDDevice
    let name: String
    let transport: String
    let connectedAt = Date()
    let bufferSize: Int
    let buffer: UnsafeMutablePointer<UInt8>
    weak var monitor: PadMonitor?

    var battery: DualSense.Battery?
    var updatedAt: Date?
    var listening = false              // in attesa di un report utile
    var registered = false             // callback dei report registrata
    var requestedFullReports = false
    var lowBatteryNotified = false
    var disposed = false
    var sampleID = 0

    init(device: IOHIDDevice, monitor: PadMonitor) {
        self.device = device
        self.monitor = monitor
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "DualSense"
        transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let size = max(maxReport, 256)
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
        bufferSize = size
        buffer = storage
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        buffer.deallocate()
    }
}

// MARK: - Lettura HID

/// Il DualSense manda centinaia di report al secondo: invece di ascoltarli tutti,
/// ogni 30 secondi registra la callback, legge un report e la toglie di nuovo.
@MainActor
final class PadMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var accessDenied = false

    private var manager: IOHIDManager?
    private var pads: [ObjectIdentifier: Pad] = [:]
    private var timer: Timer?

    private static let refreshInterval: TimeInterval = 30
    private static let notPermitted = IOReturn(bitPattern: 0xE00002E2)   // kIOReturnNotPermitted

    var connectedPads: [Pad] {
        pads.values.sorted { $0.connectedAt < $1.connectedAt }
    }

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching = DualSense.productIDs.map {
            [kIOHIDVendorIDKey: DualSense.vendorID, kIOHIDProductIDKey: $0] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<PadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.deviceConnected(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<PadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.deviceDisconnected(device) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Apertura non esclusiva: giochi e sistema continuano a usare il controller normalmente.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        accessDenied = (result == Self.notPermitted)
        Debug.log("IOHIDManagerOpen: 0x\(String(UInt32(bitPattern: result), radix: 16))")

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshAll() }
        }
    }

    func refreshAll() {
        for pad in pads.values { sample(pad) }
    }

    private func deviceConnected(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard pads[key] == nil else { return }
        let pad = Pad(device: device, monitor: self)
        pads[key] = pad
        Debug.log("collegato: \(pad.name) via \(pad.transport)")
        onChange?()
        sample(pad)
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let pad = pads.removeValue(forKey: ObjectIdentifier(device)) else { return }
        Debug.log("scollegato: \(pad.name)")
        pad.listening = false
        unregister(pad)
        pad.dispose()
        onChange?()
    }

    private func sample(_ pad: Pad) {
        guard !pad.disposed else { return }
        pad.listening = true
        pad.sampleID += 1
        let id = pad.sampleID

        if !pad.registered {
            pad.registered = true
            IOHIDDeviceRegisterInputReportCallback(pad.device, pad.buffer, pad.bufferSize, { context, result, _, _, reportID, report, length in
                guard result == kIOReturnSuccess, let context else { return }
                let pad = Unmanaged<Pad>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    pad.monitor?.received(pad, reportID: reportID, report: report, length: length)
                }
            }, Unmanaged.passUnretained(pad).toOpaque())
        }

        // Se entro qualche secondo non arriva nulla di utile, smetti di ascoltare.
        Task { @MainActor [weak self, weak pad] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let pad, pad.listening, pad.sampleID == id else { return }
            Debug.log("nessun report utile da \(pad.name)")
            pad.listening = false
            self.unregister(pad)
            if !pad.requestedFullReports { self.requestFullReports(pad) }
        }
    }

    fileprivate func received(_ pad: Pad, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard pad.listening, !pad.disposed else { return }

        guard let status = DualSense.statusByte(reportID: reportID, report: report, length: length) else {
            // In Bluetooth il controller può essere in modalità "semplice", senza batteria nei report.
            if !pad.requestedFullReports {
                Debug.log("report 0x\(String(reportID, radix: 16)) di \(length) byte senza batteria")
                pad.requestedFullReports = true
                Task { @MainActor in self.requestFullReports(pad) }
            }
            return
        }

        pad.listening = false
        Task { @MainActor in self.unregister(pad) }

        let battery = DualSense.decode(status)
        Debug.log("\(pad.name): stato 0x\(String(status, radix: 16)) → \(battery)")
        pad.battery = battery
        pad.updatedAt = Date()
        onChange?()
    }

    private func requestFullReports(_ pad: Pad) {
        guard !pad.disposed else { return }
        pad.requestedFullReports = true

        var report = [UInt8](repeating: 0, count: 64)
        report[0] = UInt8(DualSense.calibrationReportID)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(pad.device, kIOHIDReportTypeFeature,
                                          CFIndex(DualSense.calibrationReportID), &report, &length)
        Debug.log("richiesta report completi a \(pad.name): 0x\(String(UInt32(bitPattern: result), radix: 16))")

        // Riprova a breve, ora che dovrebbero arrivare i report completi.
        Task { @MainActor [weak self, weak pad] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let pad, pad.battery == nil else { return }
            self.sample(pad)
        }
    }

    private func unregister(_ pad: Pad) {
        guard pad.registered, !pad.listening, !pad.disposed else { return }
        pad.registered = false
        IOHIDDeviceRegisterInputReportCallback(pad.device, pad.buffer, pad.bufferSize, nil, nil)
    }
}

// MARK: - Barra dei menu

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: PadMonitor!

    private static let lowBatteryThreshold = 20

    private var lowBatteryAlerts: Bool {
        get { UserDefaults.standard.object(forKey: "lowBatteryAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lowBatteryAlerts") }
    }

    private var onlyWhenConnected: Bool {
        get { UserDefaults.standard.bool(forKey: "onlyWhenConnected") }
        set { UserDefaults.standard.set(newValue, forKey: "onlyWhenConnected") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "DualSenseBattery"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor = PadMonitor()
        monitor.onChange = { [weak self] in self?.refresh() }
        monitor.start()

        if lowBatteryAlerts { requestNotificationPermission() }
        refresh()
    }

    /// Riaprire l'app dal Finder fa ricomparire l'icona anche se era nascosta.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onlyWhenConnected = false
        refresh()
        return false
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let pads = monitor.connectedPads
        button.imagePosition = .imageLeading

        if pads.isEmpty {
            button.image = symbol("gamecontroller")
            button.title = ""
            button.appearsDisabled = true
            button.toolTip = "Nessun DualSense collegato"
            statusItem.isVisible = !onlyWhenConnected
        } else {
            statusItem.isVisible = true
            button.appearsDisabled = false
            var parts = [symbol("gamecontroller.fill")].compactMap { $0 }
            if pads.contains(where: { $0.battery?.state == .charging }),
               let bolt = symbol("bolt.fill", pointSize: 9) {
                parts.append(bolt)
            }
            button.image = combined(parts)
            button.title = " " + pads.map { shortLabel($0) }.joined(separator: " · ")
            button.toolTip = pads.map { "\($0.name): \(longLabel($0))" }.joined(separator: "\n")
        }

        checkLowBattery(pads)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pads = monitor.connectedPads

        if pads.isEmpty {
            menu.addItem(info("Nessun DualSense collegato"))
        }
        for pad in pads {
            menu.addItem(info("\(pad.name): \(longLabel(pad))"))
            if let updated = pad.updatedAt {
                let time = updated.formatted(date: .omitted, time: .standard)
                menu.addItem(info("Letto alle \(time) · \(pad.transport)", indented: true))
            }
        }

        if monitor.accessDenied {
            menu.addItem(.separator())
            menu.addItem(action("Consenti l'accesso al controller…", #selector(openInputMonitoring)))
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Avvisa sotto il \(Self.lowBatteryThreshold)%", on: lowBatteryAlerts, #selector(toggleAlerts)))
        menu.addItem(toggle("Mostra solo con controller collegato", on: onlyWhenConnected, #selector(toggleOnlyWhenConnected)))
        menu.addItem(toggle("Apri al login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(action("Aggiorna ora", #selector(refreshNow)))
        menu.addItem(action("Esci", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))

        // Così il valore è fresco anche alla prossima apertura.
        monitor.refreshAll()
    }

    private func info(_ title: String, indented: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if indented { item.indentationLevel = 1 }
        return item
    }

    private func action(_ title: String, _ selector: Selector, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func toggle(_ title: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleAlerts() {
        lowBatteryAlerts.toggle()
        if lowBatteryAlerts { requestNotificationPermission() }
    }

    @objc private func toggleOnlyWhenConnected() {
        onlyWhenConnected.toggle()
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Non riesco a cambiare l'apertura al login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func refreshNow() {
        monitor.refreshAll()
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Notifiche

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkLowBattery(_ pads: [Pad]) {
        for pad in pads {
            guard let battery = pad.battery else { continue }
            if battery.state == .discharging && battery.percent <= Self.lowBatteryThreshold {
                guard !pad.lowBatteryNotified else { continue }
                pad.lowBatteryNotified = true
                if lowBatteryAlerts { notifyLowBattery(pad, battery) }
            } else if battery.state != .discharging || battery.percent > Self.lowBatteryThreshold + 5 {
                pad.lowBatteryNotified = false
            }
        }
    }

    private func notifyLowBattery(_ pad: Pad, _ battery: DualSense.Battery) {
        let content = UNMutableNotificationContent()
        content.title = "Batteria del controller bassa"
        content.body = "\(pad.name): circa \(battery.percent)%. Mettilo in carica."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-battery-\(pad.connectedAt.timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Aspetto

    private func shortLabel(_ pad: Pad) -> String {
        guard let battery = pad.battery else { return "…" }
        return battery.state == .error ? "!" : "\(battery.percent)%"
    }

    private func longLabel(_ pad: Pad) -> String {
        guard let battery = pad.battery else { return "lettura in corso…" }
        switch battery.state {
        case .discharging: return "\(battery.percent)%"
        case .charging: return "\(battery.percent)%, in carica"
        case .full: return "carica completa"
        case .error: return "errore di carica"
        }
    }

    private func symbol(_ name: String, pointSize: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }

    /// Affianca più simboli in un'unica immagine template, così la barra dei menu la colora da sé.
    private func combined(_ parts: [NSImage]) -> NSImage? {
        guard parts.count > 1 else { return parts.first }
        let spacing: CGFloat = 1
        let width = parts.reduce(-spacing) { $0 + $1.size.width + spacing }
        let height = parts.map(\.size.height).max() ?? 0
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(in: NSRect(x: x, y: (height - part.size.height) / 2,
                                     width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Avvio

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
