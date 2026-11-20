import Cocoa
import CoreGraphics

@_silgen_name("DisplayServicesCanChangeBrightness")
private func displayServicesCanChangeBrightness(_ display: CGDirectDisplayID) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
private func displayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
private func displayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

private let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
private func L(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

private let appName = L("Fine Brightness", "亮度细调")
private let brightnessLabel = L("Brightness", "亮度")
private let brightnessStep: Float = 0.01
// Only used if the system brightness notification is unavailable.
private let fallbackPollInterval: TimeInterval = 1.0

@_silgen_name("DisplayServicesRegisterForBrightnessChangeNotifications")
private func displayServicesRegisterForBrightnessChangeNotifications(
    _ display: CGDirectDisplayID,
    _ observer: UnsafeRawPointer?,
    _ callback: CFNotificationCallback
) -> Int32

private let systemBrightnessDidChange = Notification.Name("FineBrightnessSystemBrightnessDidChange")

// The system calls this whenever display brightness changes, whether from the
// keyboard, Control Center, auto-brightness or this app.
private let brightnessChangeCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: systemBrightnessDidChange, object: nil)
    }
}

final class BrightnessController {
    func currentBrightness() -> Float? {
        for display in targetDisplays() {
            if let brightness = readBrightness(from: display) {
                return brightness
            }
        }

        return nil
    }

    func setBrightness(_ brightness: Float) -> Bool {
        let value = clamp(brightness)
        var didSet = false

        for display in targetDisplays() {
            if setBrightness(value, on: display) {
                didSet = true
            }
        }

        return didSet
    }

    /// Registers for system brightness change notifications on every adjustable
    /// display not registered yet. Returns false if any registration failed.
    func observeBrightnessChanges(alreadyObserved: inout Set<CGDirectDisplayID>) -> Bool {
        var allSucceeded = true
        for display in targetDisplays() where !alreadyObserved.contains(display) {
            if displayServicesRegisterForBrightnessChangeNotifications(display, nil, brightnessChangeCallback) == 0 {
                alreadyObserved.insert(display)
            } else {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    func changeBrightness(by delta: Float) -> Float? {
        let current = currentBrightness() ?? 0.5
        let next = clamp(current + delta)
        return setBrightness(next) ? next : nil
    }

    private func targetDisplays() -> [CGDirectDisplayID] {
        let displays = activeDisplays()
        let adjustableDisplays = displays.filter { displayServicesCanChangeBrightness($0) != 0 }
        let builtInDisplays = adjustableDisplays.filter { CGDisplayIsBuiltin($0) != 0 }
        return builtInDisplays.isEmpty ? adjustableDisplays : builtInDisplays
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = CGGetActiveDisplayList(0, nil, &count)
        guard countError == .success, count > 0 else {
            return [CGMainDisplayID()]
        }

        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let listError = CGGetActiveDisplayList(count, &displays, &count)
        guard listError == .success else {
            return [CGMainDisplayID()]
        }

        return displays.filter { $0 != 0 }
    }

    private func readBrightness(from display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        let result = displayServicesGetBrightness(display, &value)
        guard result == 0 else {
            return nil
        }

        return clamp(value)
    }

    private func setBrightness(_ brightness: Float, on display: CGDirectDisplayID) -> Bool {
        displayServicesSetBrightness(display, brightness) == 0
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let brightnessController = BrightnessController()
    private let menu = NSMenu()
    private let headerItem = NSMenuItem(title: brightnessLabel, action: nil, keyEquivalent: "")
    private let sliderItem = NSMenuItem()
    private let menuSlider = NSSlider(value: 0.5, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let menuPercentLabel = NSTextField(labelWithString: "--%")
    private let windowSlider = NSSlider(value: 0.5, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let windowPercentLabel = NSTextField(labelWithString: "--%")
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var isUpdatingControls = false
    private var displayedBrightness: Float?
    private var observedDisplays = Set<CGDirectDisplayID>()
    private var fallbackTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureStatusItem()
        configureMenu()
        configureWindow()
        refreshFromSystem()
        startSyncingWithSystem()
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshFromSystem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshFromSystem()
    }

    private func configureStatusItem() {
        // New status items are added on the far left, the first place macOS hides
        // them when the menu bar is crowded. On first launch, start next to the
        // system items instead; after that, wherever the user drags it is kept.
        let positionKey = "NSStatusItem Preferred Position FineBrightnessStatusItem"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(330.0, forKey: positionKey)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "FineBrightnessStatusItem"
        if let button = item.button {
            // Keep the item narrow so it still fits on crowded menu bars
            // next to the notch: a sun icon plus the percentage.
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: brightnessLabel)?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.title = "--%"
            button.toolTip = appName
        }

        item.menu = menu
        statusItem = item
    }

    private func configureMenu() {
        menu.delegate = self

        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(sliderItem)
        menu.addItem(NSMenuItem.separator())

        let decreaseItem = NSMenuItem(title: "- 1%", action: #selector(decreaseBrightness), keyEquivalent: "")
        decreaseItem.target = self
        menu.addItem(decreaseItem)

        let increaseItem = NSMenuItem(title: "+ 1%", action: #selector(increaseBrightness), keyEquivalent: "")
        increaseItem.target = self
        menu.addItem(increaseItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: L("Refresh", "刷新"), action: #selector(refreshBrightness), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: L("Quit Fine Brightness", "退出亮度细调"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        configureSliderView()
    }

    private func configureSliderView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))

        menuSlider.target = self
        menuSlider.action = #selector(sliderChanged)
        menuSlider.isContinuous = true
        menuSlider.translatesAutoresizingMaskIntoConstraints = false

        menuPercentLabel.alignment = .right
        menuPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        menuPercentLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(menuSlider)
        container.addSubview(menuPercentLabel)

        NSLayoutConstraint.activate([
            menuSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            menuSlider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            menuSlider.trailingAnchor.constraint(equalTo: menuPercentLabel.leadingAnchor, constant: -10),

            menuPercentLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            menuPercentLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            menuPercentLabel.widthAnchor.constraint(equalToConstant: 42)
        ])

        sliderItem.view = container
    }

    private func configureWindow() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 138))

        let titleLabel = NSTextField(labelWithString: appName)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        windowPercentLabel.alignment = .right
        windowPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        windowPercentLabel.translatesAutoresizingMaskIntoConstraints = false

        windowSlider.target = self
        windowSlider.action = #selector(sliderChanged)
        windowSlider.isContinuous = true
        windowSlider.translatesAutoresizingMaskIntoConstraints = false

        let decreaseButton = NSButton(title: "- 1%", target: self, action: #selector(decreaseBrightness))
        decreaseButton.bezelStyle = .rounded
        decreaseButton.translatesAutoresizingMaskIntoConstraints = false

        let increaseButton = NSButton(title: "+ 1%", target: self, action: #selector(increaseBrightness))
        increaseButton.bezelStyle = .rounded
        increaseButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(windowPercentLabel)
        contentView.addSubview(windowSlider)
        contentView.addSubview(decreaseButton)
        contentView.addSubview(increaseButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

            windowPercentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            windowPercentLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            windowPercentLabel.widthAnchor.constraint(equalToConstant: 62),

            windowSlider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            windowSlider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            windowSlider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),

            decreaseButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            decreaseButton.topAnchor.constraint(equalTo: windowSlider.bottomAnchor, constant: 16),
            decreaseButton.widthAnchor.constraint(equalToConstant: 96),

            increaseButton.leadingAnchor.constraint(equalTo: decreaseButton.trailingAnchor, constant: 12),
            increaseButton.topAnchor.constraint(equalTo: decreaseButton.topAnchor),
            increaseButton.widthAnchor.constraint(equalToConstant: 96)
        ])

        let appWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 138),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        appWindow.title = appName
        appWindow.contentView = contentView
        appWindow.center()
        appWindow.isReleasedWhenClosed = false
        window = appWindow
    }

    private func startSyncingWithSystem() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemBrightnessChanged),
            name: systemBrightnessDidChange,
            object: nil
        )
        observeDisplays()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        observeDisplays()
        refreshFromSystem()
    }

    @objc private func systemBrightnessChanged() {
        syncWithSystem()
    }

    private func observeDisplays() {
        let ok = brightnessController.observeBrightnessChanges(alreadyObserved: &observedDisplays)
        if ok && !observedDisplays.isEmpty {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
        } else if fallbackTimer == nil {
            let timer = Timer(timeInterval: fallbackPollInterval, repeats: true) { [weak self] _ in
                self?.syncWithSystem()
            }
            timer.tolerance = fallbackPollInterval / 2
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func syncWithSystem() {
        guard let value = brightnessController.currentBrightness() else {
            return
        }

        if let shown = displayedBrightness, abs(shown - value) < 0.0005 {
            return
        }

        updateControls(with: value)
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !isUpdatingControls else {
            return
        }

        let value = Float(sender.doubleValue)
        if brightnessController.setBrightness(value) {
            updateControls(with: value)
        } else {
            showUnavailableState()
        }
    }

    @objc private func decreaseBrightness() {
        adjustBrightness(by: -brightnessStep)
    }

    @objc private func increaseBrightness() {
        adjustBrightness(by: brightnessStep)
    }

    @objc private func refreshBrightness() {
        refreshFromSystem()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func adjustBrightness(by delta: Float) {
        if let value = brightnessController.changeBrightness(by: delta) {
            updateControls(with: value)
        } else {
            showUnavailableState()
        }
    }

    private func refreshFromSystem() {
        if let value = brightnessController.currentBrightness() {
            updateControls(with: value)
        } else {
            showUnavailableState()
        }
    }

    private func updateControls(with brightness: Float) {
        let percent = Int((brightness * 100).rounded())
        displayedBrightness = brightness

        isUpdatingControls = true
        menuSlider.isEnabled = true
        windowSlider.isEnabled = true
        menuSlider.floatValue = brightness
        windowSlider.floatValue = brightness
        menuPercentLabel.stringValue = "\(percent)%"
        windowPercentLabel.stringValue = "\(percent)%"
        headerItem.title = "\(brightnessLabel) \(percent)%"
        statusItem?.button?.title = "\(percent)%"
        statusItem?.button?.toolTip = "\(appName) \(percent)%"
        isUpdatingControls = false
    }

    private func showUnavailableState() {
        displayedBrightness = nil
        isUpdatingControls = true
        menuSlider.isEnabled = false
        windowSlider.isEnabled = false
        menuPercentLabel.stringValue = "--%"
        windowPercentLabel.stringValue = "--%"
        headerItem.title = L("Unable to read display brightness", "无法读取屏幕亮度")
        statusItem?.button?.title = "--%"
        statusItem?.button?.toolTip = "\(appName): " + L("Unable to read brightness", "无法读取亮度")
        isUpdatingControls = false
        NSSound.beep()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
