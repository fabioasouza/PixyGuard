import AppKit
import CoreGraphics
import AVFoundation
import Carbon
import Foundation
import ServiceManagement

private struct HelperResult {
    let status: Int32
    let output: String
}

private struct CameraPreset {
    let title: String
    let pan: Double
    let tilt: Double
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum HotKey: UInt32 {
        case moveUp = 1
        case moveDown = 2
        case moveLeft = 3
        case moveRight = 4
        case recenter = 5
        case tracking = 6
    }

    private static let hotKeySignature = OSType(0x50584252)
    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        if status == noErr && hotKeyID.signature == AppDelegate.hotKeySignature {
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.handleHotKey(id: hotKeyID.id)
            }
        }

        return noErr
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let statusLabel = NSTextField(labelWithString: "Checking...")
    private let lastResultLabel = NSTextField(labelWithString: "Ready")
    private let moveStepOptions: [Double] = [1.0, 3.0, 10.0]
    private let presets: [CameraPreset] = [
        CameraPreset(title: "Centro", pan: 0.0, tilt: 0.0),
        CameraPreset(title: "Mesa", pan: 0.0, tilt: -12.0),
        CameraPreset(title: "Em pé", pan: 0.0, tilt: 8.0),
        CameraPreset(title: "Quadro", pan: -18.0, tilt: 0.0)
    ]

    private var refreshMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var trackingButton: NSButton?
    private var stepControl: NSSegmentedControl?
    private var presetControl: NSSegmentedControl?
    private var controlButtons: [NSButton] = []
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    // MARK: - PixyGuard automation
    private let guardDefaults = UserDefaults.standard
    private var guardPrivacyOnLock = true
    private var guardAutoTracking = true
    private var guardNormalWhenIdle = true
    private var guardSleeping = false
    private var guardCurrentMode = "unknown"
    private var guardTimer: Timer?
    private var guardPendingMode: String?
    private var guardPendingSince = Date.distantPast
    private let guardDebounceSeconds: TimeInterval = 0.5
    private var guardPrivacyButton: NSButton?
    private var guardTrackingButton: NSButton?
    private var guardIdleButton: NSButton?
    private let guardFallbackLabel = NSTextField(labelWithString: "Fallback: —")

    private var pixyConnected = false
    private var trackingEnabled = false
    private var helperRunning = false
    private var moveStepDegrees = 3.0
    private var currentPan = 0.0
    private var currentTilt = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadGuardPreferences()
        configureStatusItem()
        buildMenu()
        registerHotKeys()
        refreshStatus()
        startGuardAutomation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guardTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        unregisterHotKeys()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = makePixyStatusIcon()
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
            button.toolTip = "PixyGuard"
        }
        statusItem.menu = menu
    }

    private func makePixyStatusIcon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let head = NSBezierPath(roundedRect: NSRect(x: 3.2, y: 6.0, width: 15.6, height: 9.6), xRadius: 3.2, yRadius: 3.2)
            head.lineWidth = 1.7
            head.stroke()

            NSBezierPath(ovalIn: NSRect(x: 6.2, y: 8.3, width: 4.1, height: 4.1)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.0, y: 8.7, width: 3.2, height: 3.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 16.0, y: 12.8, width: 1.4, height: 1.4)).fill()

            let neck = NSBezierPath(roundedRect: NSRect(x: 10.1, y: 4.2, width: 1.8, height: 2.4), xRadius: 0.9, yRadius: 0.9)
            neck.fill()

            let base = NSBezierPath(roundedRect: NSRect(x: 6.6, y: 2.0, width: 8.8, height: 3.1), xRadius: 1.55, yRadius: 1.55)
            base.fill()

            return true
        }
        image.accessibilityDescription = "PixyGuard"
        image.isTemplate = true
        return image
    }

    private func buildMenu() {
        menu.addItem(makeHeaderMenuItem())
        menu.addItem(.separator())
        menu.addItem(makeControlsMenuItem())
        menu.addItem(.separator())
        menu.addItem(makeAutomationMenuItem())
        menu.addItem(.separator())

        let refresh = item("Atualizar", #selector(refreshStatus))
        refreshMenuItem = refresh
        menu.addItem(refresh)

        let launchAtLogin = item("Abrir ao iniciar sessão", #selector(toggleLaunchAtLogin))
        launchAtLoginMenuItem = launchAtLogin
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        menu.addItem(item("Sair", #selector(quit)))

        updateLaunchAtLoginState()
        updateMenuState()
    }

    private func makeHeaderMenuItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 258, height: 66))

        let imageView = NSImageView(frame: NSRect(x: 16, y: 22, width: 28, height: 22))
        imageView.image = makePixyStatusIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(imageView)

        let title = NSTextField(labelWithString: "PixyGuard")
        title.frame = NSRect(x: 54, y: 41, width: 188, height: 18)
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        view.addSubview(title)

        configureHeaderLabel(statusLabel, frame: NSRect(x: 54, y: 24, width: 188, height: 15), color: .secondaryLabelColor)
        view.addSubview(statusLabel)

        configureHeaderLabel(lastResultLabel, frame: NSRect(x: 54, y: 8, width: 188, height: 15), color: .tertiaryLabelColor)
        view.addSubview(lastResultLabel)

        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func configureHeaderLabel(_ label: NSTextField, frame: NSRect, color: NSColor) {
        label.frame = frame
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = color
        label.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byTruncatingTail
    }

    private func makeControlsMenuItem() -> NSMenuItem {
        controlButtons.removeAll()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 258, height: 334))
        let cameraLabel = sectionLabel("Câmera", frame: NSRect(x: 16, y: 309, width: 226, height: 16))
        view.addSubview(cameraLabel)

        view.addSubview(controlButton(title: "Ligada", symbolName: "video", action: #selector(cameraOn), toolTip: "Camera On", frame: NSRect(x: 16, y: 274, width: 69, height: 30)))

        let track = controlButton(title: "Tracking", symbolName: "scope", action: #selector(toggleTracking), toolTip: "AI Tracking", frame: NSRect(x: 94, y: 274, width: 70, height: 30))
        track.setButtonType(.toggle)
        trackingButton = track
        view.addSubview(track)

        view.addSubview(controlButton(title: "Privacy", symbolName: "video.slash", action: #selector(cameraOff), toolTip: "Camera Off", frame: NSRect(x: 173, y: 274, width: 69, height: 30)))

        let trackingHint = NSTextField(labelWithString: "Tracking funciona enquanto o vídeo estiver aberto")
        trackingHint.frame = NSRect(x: 16, y: 252, width: 226, height: 16)
        trackingHint.font = NSFont.systemFont(ofSize: 11)
        trackingHint.textColor = .tertiaryLabelColor
        trackingHint.usesSingleLineMode = true
        trackingHint.cell?.lineBreakMode = .byTruncatingTail
        view.addSubview(trackingHint)

        let stepLabel = sectionLabel("Passo", frame: NSRect(x: 16, y: 226, width: 226, height: 16))
        view.addSubview(stepLabel)
        let step = NSSegmentedControl(frame: NSRect(x: 16, y: 196, width: 226, height: 26))
        step.segmentCount = moveStepOptions.count
        step.trackingMode = .selectOne
        step.segmentStyle = .rounded
        step.target = self
        step.action = #selector(stepChanged)
        for (index, degrees) in moveStepOptions.enumerated() {
            step.setLabel("\(Int(degrees)) deg", forSegment: index)
            step.setWidth(72, forSegment: index)
        }
        step.selectedSegment = 1
        stepControl = step
        view.addSubview(step)

        let moveLabel = sectionLabel("Mover", frame: NSRect(x: 16, y: 166, width: 226, height: 16))
        view.addSubview(moveLabel)

        view.addSubview(controlButton(title: "", symbolName: "chevron.up", action: #selector(moveUp), toolTip: "Move Up", frame: NSRect(x: 110, y: 132, width: 38, height: 30)))
        view.addSubview(controlButton(title: "", symbolName: "chevron.left", action: #selector(moveLeft), toolTip: "Move Left", frame: NSRect(x: 66, y: 98, width: 38, height: 30)))
        view.addSubview(controlButton(title: "", symbolName: "smallcircle.filled.circle", action: #selector(recenter), toolTip: "Recenter", frame: NSRect(x: 110, y: 98, width: 38, height: 30)))
        view.addSubview(controlButton(title: "", symbolName: "chevron.right", action: #selector(moveRight), toolTip: "Move Right", frame: NSRect(x: 154, y: 98, width: 38, height: 30)))
        view.addSubview(controlButton(title: "", symbolName: "chevron.down", action: #selector(moveDown), toolTip: "Move Down", frame: NSRect(x: 110, y: 64, width: 38, height: 30)))

        let presetLabel = sectionLabel("Posições", frame: NSRect(x: 16, y: 42, width: 226, height: 16))
        view.addSubview(presetLabel)

        let presetsControl = NSSegmentedControl(frame: NSRect(x: 16, y: 12, width: 226, height: 28))
        presetsControl.segmentCount = presets.count
        presetsControl.trackingMode = .selectOne
        presetsControl.segmentStyle = .rounded
        presetsControl.target = self
        presetsControl.action = #selector(presetChanged)
        for (index, preset) in presets.enumerated() {
            presetsControl.setLabel(preset.title, forSegment: index)
            presetsControl.setWidth(56, forSegment: index)
        }
        presetControl = presetsControl
        view.addSubview(presetsControl)

        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func makeAutomationMenuItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 258, height: 126))

        let label = sectionLabel("Automação", frame: NSRect(x: 16, y: 104, width: 226, height: 16))
        view.addSubview(label)

        let privacy = NSButton(checkboxWithTitle: "Privacy ao bloquear / repousar", target: self, action: #selector(toggleGuardPrivacy(_:)))
        privacy.frame = NSRect(x: 16, y: 77, width: 226, height: 20)
        privacy.font = NSFont.systemFont(ofSize: 11)
        privacy.state = guardPrivacyOnLock ? .on : .off
        privacy.toolTip = "Vira fisicamente a PIXY ao bloquear ou colocar o Mac em repouso."
        guardPrivacyButton = privacy
        view.addSubview(privacy)

        let tracking = NSButton(checkboxWithTitle: "Tracking automático quando em uso", target: self, action: #selector(toggleGuardTracking(_:)))
        tracking.frame = NSRect(x: 16, y: 53, width: 226, height: 20)
        tracking.font = NSFont.systemFont(ofSize: 11)
        tracking.state = guardAutoTracking ? .on : .off
        tracking.toolTip = "Ativa tracking quando qualquer app abrir o vídeo da PIXY."
        guardTrackingButton = tracking
        view.addSubview(tracking)

        let idle = NSButton(checkboxWithTitle: "Voltar ao Normal ao fechar o stream", target: self, action: #selector(toggleGuardIdle(_:)))
        idle.frame = NSRect(x: 16, y: 29, width: 226, height: 20)
        idle.font = NSFont.systemFont(ofSize: 11)
        idle.state = guardNormalWhenIdle ? .on : .off
        idle.toolTip = "Volta ao modo Normal quando nenhum aplicativo estiver usando a PIXY."
        guardIdleButton = idle
        view.addSubview(idle)

        guardFallbackLabel.frame = NSRect(x: 16, y: 7, width: 226, height: 16)
        guardFallbackLabel.font = NSFont.systemFont(ofSize: 10.5)
        guardFallbackLabel.textColor = .tertiaryLabelColor
        guardFallbackLabel.usesSingleLineMode = true
        guardFallbackLabel.cell?.lineBreakMode = .byTruncatingTail
        view.addSubview(guardFallbackLabel)
        updateGuardFallbackLabel()

        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func loadGuardPreferences() {
        guardPrivacyOnLock = guardDefaults.object(forKey: "privacyOnLock") as? Bool ?? true
        guardAutoTracking = guardDefaults.object(forKey: "autoTracking") as? Bool ?? true
        guardNormalWhenIdle = guardDefaults.object(forKey: "normalWhenIdle") as? Bool ?? true
    }

    @objc private func toggleGuardPrivacy(_ sender: NSButton) {
        guardPrivacyOnLock = sender.state == .on
        guardDefaults.set(guardPrivacyOnLock, forKey: "privacyOnLock")
        guardCurrentMode = "unknown"
        guardTick()
    }

    @objc private func toggleGuardTracking(_ sender: NSButton) {
        guardAutoTracking = sender.state == .on
        guardDefaults.set(guardAutoTracking, forKey: "autoTracking")
        guardCurrentMode = "unknown"
        guardTick()
    }

    @objc private func toggleGuardIdle(_ sender: NSButton) {
        guardNormalWhenIdle = sender.state == .on
        guardDefaults.set(guardNormalWhenIdle, forKey: "normalWhenIdle")
        guardCurrentMode = "unknown"
        guardTick()
    }

    private func startGuardAutomation() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(guardWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(guardDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        guardTick()
        guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.guardTick()
        }
    }

    private func guardVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .video)
    }

    private func guardIsPixy(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.uppercased()
        return name.contains("PIXY") || (name.contains("EMEET") && name.contains("PIX"))
    }

    private func guardPixyDevice() -> AVCaptureDevice? {
        guardVideoDevices().first { guardIsPixy($0) && $0.isConnected }
    }

    private func guardFallbackDevice() -> AVCaptureDevice? {
        let candidates = guardVideoDevices().filter { !guardIsPixy($0) && $0.isConnected }
        return candidates.first {
            let name = $0.localizedName.lowercased()
            return name.contains("built-in") || name.contains("facetime") || name.contains("macbook")
        } ?? candidates.first
    }

    private func updateGuardFallbackLabel() {
        let name = guardFallbackDevice()?.localizedName ?? "—"
        guardFallbackLabel.stringValue = "Fallback: \(name)"
        guardFallbackLabel.toolTip = guardFallbackLabel.stringValue
    }

    private func guardPixyIsRunning() -> Bool {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("pixyusage")
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func guardScreenLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // Fail closed: if lock state cannot be determined, prefer privacy.
            return true
        }
        if let value = dictionary["CGSSessionScreenIsLocked"] as? Bool { return value }
        if let value = dictionary["CGSSessionScreenIsLocked"] as? NSNumber { return value.boolValue }
        return false
    }

    private func guardApplyMode(_ mode: String) {
        guard !helperRunning else { return }
        guard pixyConnected else { return }

        runHelper(["mode", mode]) { result in
            if result.status == 0 {
                self.guardCurrentMode = mode
                self.trackingEnabled = mode == "tracking"
                self.setLast(result.output)
            }
        }
    }

    private func guardTick() {
        updateGuardFallbackLabel()
        guard let pixy = guardPixyDevice(), pixy.isConnected else {
            guardCurrentMode = "disconnected"
            guardPendingMode = nil
            return
        }

        let locked = guardScreenLocked() || guardSleeping
        let inUse = guardPixyIsRunning()
        let desired: String?

        if locked && guardPrivacyOnLock {
            desired = "privacy"
        } else if inUse && guardAutoTracking {
            desired = "tracking"
        } else if !inUse && guardNormalWhenIdle {
            desired = "normal"
        } else {
            desired = nil
        }

        guard let desired else {
            guardPendingMode = nil
            return
        }

        // Privacy is safety-critical: apply immediately. Normal/tracking are debounced
        // so browser/call transitions do not flap the camera mode.
        if desired == "privacy" {
            guardPendingMode = nil
            if desired != guardCurrentMode { guardApplyMode(desired) }
            return
        }

        if desired == guardCurrentMode {
            guardPendingMode = nil
            return
        }

        if guardPendingMode != desired {
            guardPendingMode = desired
            guardPendingSince = Date()
            return
        }

        if Date().timeIntervalSince(guardPendingSince) >= guardDebounceSeconds {
            guardPendingMode = nil
            guardApplyMode(desired)
        }
    }

    @objc private func guardWillSleep() {
        guardSleeping = true
        if guardPrivacyOnLock {
            guardCurrentMode = "unknown"
            guardApplyMode("privacy")
        }
    }

    @objc private func guardDidWake() {
        guardSleeping = false
        guardCurrentMode = "unknown"
        guardTick()
    }

    private func sectionLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func controlButton(title: String, symbolName: String, action: Selector, toolTip: String, frame: NSRect) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.toolTip = toolTip

        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.imageScaling = .scaleProportionallyDown
        } else if title.isEmpty {
            button.title = toolTip
        }

        controlButtons.append(button)
        return button
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func updateMenuState() {
        trackingButton?.state = trackingEnabled ? .on : .off

        let controlsEnabled = pixyConnected && !helperRunning
        for button in controlButtons {
            button.isEnabled = controlsEnabled
        }
        stepControl?.isEnabled = !helperRunning
        presetControl?.isEnabled = controlsEnabled
        refreshMenuItem?.isEnabled = !helperRunning
    }

    private func updateLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else {
            launchAtLoginMenuItem?.isEnabled = false
            return
        }

        let status = SMAppService.mainApp.status
        launchAtLoginMenuItem?.state = status == .enabled ? .on : .off
    }

    private func registerHotKeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef)

        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let keys: [(HotKey, UInt32)] = [
            (.moveUp, UInt32(kVK_UpArrow)),
            (.moveDown, UInt32(kVK_DownArrow)),
            (.moveLeft, UInt32(kVK_LeftArrow)),
            (.moveRight, UInt32(kVK_RightArrow)),
            (.recenter, UInt32(kVK_ANSI_C)),
            (.tracking, UInt32(kVK_ANSI_T))
        ]

        for (hotKey, keyCode) in keys {
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: hotKey.rawValue)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func handleHotKey(id: UInt32) {
        guard !helperRunning else {
            NSSound.beep()
            return
        }

        if id != HotKey.tracking.rawValue && id != HotKey.recenter.rawValue && !pixyConnected {
            NSSound.beep()
            return
        }

        switch HotKey(rawValue: id) {
        case .moveUp:
            moveUp()
        case .moveDown:
            moveDown()
        case .moveLeft:
            moveLeft()
        case .moveRight:
            moveRight()
        case .recenter:
            recenter()
        case .tracking:
            toggleTracking()
        case nil:
            break
        }
    }

    private func helperPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("pixyctl")
            .path
    }

    private func runHelper(_ args: [String], completion: @escaping (HelperResult) -> Void) {
        helperRunning = true
        updateMenuState()

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: self.helperPath())
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.helperRunning = false
                    completion(HelperResult(status: process.terminationStatus, output: text))
                    self.updateMenuState()
                }
            } catch {
                DispatchQueue.main.async {
                    self.helperRunning = false
                    completion(HelperResult(status: 127, output: "Could not run pixyctl: \(error.localizedDescription)"))
                    self.updateMenuState()
                }
            }
        }
    }

    private func setLast(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        let friendly = friendlyResultText(clean)
        let display = friendly.count > 42 ? String(friendly.prefix(39)) + "..." : friendly
        lastResultLabel.stringValue = display.isEmpty ? "Done" : display
        lastResultLabel.toolTip = clean.isEmpty ? nil : clean
        statusItem.button?.toolTip = clean.isEmpty ? "PixyGuard" : clean
    }

    private func friendlyResultText(_ text: String) -> String {
        let lower = text.lowercased()

        if lower.isEmpty {
            return "Done"
        }
        if lower.contains("connected via macos iokit hid") {
            return "Connected"
        }
        if lower.hasPrefix("mode:") {
            return friendlyModeText(lower)
        }
        if lower.contains("set pixy mode:") {
            return friendlyModeText(lower)
        }
        if lower.contains("target tracking: off") {
            return "Tracking off"
        }
        if lower.contains("set pixy ai tracking") || lower.contains("target tracking: on") {
            return "Tracking on"
        }
        if lower.contains("recentered pixy") {
            return "Centered"
        }
        if lower.contains("set pixy position") {
            return "Position set"
        }
        if lower.contains("moved pixy") {
            return friendlyMoveText(lower)
        }

        return text
            .replacingOccurrences(of: "PIXY", with: "Pixy")
            .replacingOccurrences(of: "EMEET ", with: "")
    }

    private func friendlyModeText(_ lower: String) -> String {
        if lower.contains("privacy") {
            return "Privacy mode"
        }
        if lower.contains("tracking") {
            return "Tracking mode"
        }
        if lower.contains("startup") {
            return "Starting up"
        }
        if lower.contains("normal") || lower.contains("manual") {
            return "Camera on"
        }
        return "Mode updated"
    }

    private func friendlyMoveText(_ lower: String) -> String {
        for direction in ["left", "right", "up", "down"] where lower.contains(" \(direction) ") {
            return "Moved \(direction) \(degreeArgument(moveStepDegrees)) deg"
        }
        return "Moved camera"
    }

    private func degreeArgument(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private func clampDegrees(_ value: Double) -> Double {
        min(90.0, max(-90.0, value))
    }

    private func updateTrackedPosition(afterMove direction: String) {
        switch direction {
        case "left":
            currentPan = clampDegrees(currentPan - moveStepDegrees)
        case "right":
            currentPan = clampDegrees(currentPan + moveStepDegrees)
        case "up":
            currentTilt = clampDegrees(currentTilt + moveStepDegrees)
        case "down":
            currentTilt = clampDegrees(currentTilt - moveStepDegrees)
        default:
            break
        }
    }

    private func updateModeFromOutput(_ output: String) {
        let lower = output.lowercased()
        if lower.contains("tracking") || lower.contains("(1)") {
            trackingEnabled = true
            guardCurrentMode = "tracking"
        } else if lower.contains("privacy") || lower.contains("(2)") {
            trackingEnabled = false
            guardCurrentMode = "privacy"
        } else if lower.contains("normal") || lower.contains("manual") || lower.contains("(0)") {
            trackingEnabled = false
            guardCurrentMode = "normal"
        }
        updateMenuState()
    }

    private func setMode(_ mode: String, tracking: Bool) {
        runHelper(["mode", mode]) { result in
            if result.status == 0 {
                self.trackingEnabled = tracking
                self.guardCurrentMode = mode
            } else {
                NSSound.beep()
            }
            self.setLast(result.output)
            self.refreshStatus()
        }
    }

    private func setTracking(_ enabled: Bool) {
        runHelper(["mode", enabled ? "tracking" : "normal"]) { result in
            if result.status == 0 {
                self.trackingEnabled = enabled
                self.guardCurrentMode = enabled ? "tracking" : "normal"
            } else {
                NSSound.beep()
            }
            self.setLast(result.output)
            self.refreshStatus()
        }
    }

    private func statusTitle(for result: HelperResult) -> String {
        if result.status == 0 {
            return "Connected"
        }

        let output = result.output.lowercased()
        if output.contains("could not be opened") {
            return "Busy in another camera app"
        }
        if output.contains("not found") {
            return "Camera not found"
        }

        return "Camera not available"
    }

    @objc private func refreshStatus() {
        runHelper(["status"]) { result in
            self.pixyConnected = result.status == 0
            self.statusLabel.stringValue = self.statusTitle(for: result)
            self.setLast(result.output)
            self.updateMenuState()
            if self.pixyConnected {
                self.refreshMode()
            }
        }
    }

    private func refreshMode() {
        runHelper(["get-mode"]) { result in
            if result.status == 0 {
                self.updateModeFromOutput(result.output)
                self.setLast(result.output)
            }
        }
    }

    @objc private func cameraOn() {
        setMode("normal", tracking: false)
    }

    @objc private func cameraOff() {
        setMode("privacy", tracking: false)
    }

    @objc private func toggleTracking() {
        if trackingEnabled {
            setTracking(false)
        } else {
            setTracking(true)
        }
    }

    private func move(_ direction: String) {
        runHelper(["move", direction, degreeArgument(moveStepDegrees)]) { result in
            if result.status == 0 {
                self.trackingEnabled = false
                self.guardCurrentMode = "normal"
                self.updateTrackedPosition(afterMove: direction)
            } else {
                NSSound.beep()
            }
            self.setLast(result.output)
            self.refreshStatus()
        }
    }

    @objc private func moveUp() {
        move("up")
    }

    @objc private func moveDown() {
        move("down")
    }

    @objc private func moveLeft() {
        move("left")
    }

    @objc private func moveRight() {
        move("right")
    }

    @objc private func recenter() {
        runHelper(["recenter"]) { result in
            if result.status == 0 {
                self.trackingEnabled = false
                self.guardCurrentMode = "normal"
                self.currentPan = 0.0
                self.currentTilt = 0.0
            } else {
                NSSound.beep()
            }
            self.setLast(result.output)
            self.refreshStatus()
        }
    }

    @objc private func stepChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0 && index < moveStepOptions.count else {
            return
        }
        moveStepDegrees = moveStepOptions[index]
        setLast("Move step: \(degreeArgument(moveStepDegrees)) degrees")
    }

    @objc private func presetChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0 && index < presets.count else {
            return
        }

        let preset = presets[index]
        runHelper(["position", degreeArgument(preset.pan), degreeArgument(preset.tilt)]) { result in
            if result.status == 0 {
                self.trackingEnabled = false
                self.guardCurrentMode = "normal"
                self.currentPan = preset.pan
                self.currentTilt = preset.tilt
            } else {
                NSSound.beep()
            }
            self.setLast(result.output)
            self.refreshStatus()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            NSSound.beep()
            setLast("Launch at Login requires macOS 13 or newer")
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                setLast("Launch at Login off")
            } else {
                try SMAppService.mainApp.register()
                setLast("Launch at Login on")
            }
        } catch {
            NSSound.beep()
            setLast("Launch at Login failed: \(error.localizedDescription)")
        }

        updateLaunchAtLoginState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
