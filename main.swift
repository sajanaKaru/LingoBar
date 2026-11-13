import SwiftUI
import AppKit
import ApplicationServices
import Carbon
import Combine

// MARK: - App Entry Point
@main
struct LingoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Native Carbon Global Hotkey Manager
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    var onTrigger: (() -> Void)?
    var hasRegistrationConflict: Bool = false

    func setup() -> Bool {
        teardown()
        hasRegistrationConflict = false

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, theEvent, _ -> OSStatus in
            guard let theEvent = theEvent else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                DispatchQueue.main.async {
                    GlobalHotKeyManager.shared.onTrigger?()
                }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
        guard installStatus == noErr else {
            NSLog("[LingoBar] InstallEventHandler failed with status: %d", installStatus)
            hasRegistrationConflict = true
            return false
        }

        // 1. Option + Space (kVK_Space = 49, optionKey = 0x0800)
        let spaceID = EventHotKeyID(signature: OSType(0x4C4E4742), id: 1) // 'LNGB', 1
        var spaceRef: EventHotKeyRef?
        let spaceStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), spaceID, GetApplicationEventTarget(), 0, &spaceRef)
        if spaceStatus == noErr, let r = spaceRef {
            hotKeyRefs.append(r)
            NSLog("[LingoBar] Successfully registered Carbon Global HotKey: Option+Space")
        } else {
            NSLog("[LingoBar] Failed to register Carbon Global HotKey Option+Space with status: %d", spaceStatus)
            hasRegistrationConflict = true
        }

        // 2. Option + Shift + L (kVK_ANSI_L = 37, optionKey | shiftKey)
        let lID = EventHotKeyID(signature: OSType(0x4C4E4742), id: 2) // 'LNGB', 2
        var lRef: EventHotKeyRef?
        let lStatus = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(optionKey | shiftKey), lID, GetApplicationEventTarget(), 0, &lRef)
        if lStatus == noErr, let r = lRef {
            hotKeyRefs.append(r)
            NSLog("[LingoBar] Successfully registered Carbon Global HotKey: Option+Shift+L")
        } else {
            NSLog("[LingoBar] Failed to register Carbon Global HotKey Option+Shift+L with status: %d", lStatus)
            hasRegistrationConflict = true
        }

        // If any hotkey registration failed, unregister any already registered hotkeys
        if hasRegistrationConflict {
            for ref in hotKeyRefs {
                UnregisterEventHotKey(ref)
            }
            hotKeyRefs.removeAll()
            return false
        }

        return true
    }

    func teardown() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}

// MARK: - Lightweight Non-Activating Inline Popover Panel
final class InlinePopoverPanel: NSPanel {
    var allowKeyForInput: Bool = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool {
        return allowKeyForInput
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// MARK: - App Delegate & Coordinate-Anchored Inline Popover Lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: InlinePopoverPanel!
    var statusItem: NSStatusItem?
    var viewModel = PopoverViewModel()
    var settingsWindow: NSWindow?
    
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var globalScrollMonitor: Any?
    private var hostingController: NSHostingController<InlinePopoverView>?
    private var cancellables = Set<AnyCancellable>()
    private var currentAnchorRect: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popoverView = InlinePopoverView(
            vm: viewModel,
            onClose: { [weak self] in
                self?.dismissPopover()
            }
        )

        let hc = NSHostingController(rootView: popoverView)
        self.hostingController = hc

        panel = InlinePopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140))
        panel.contentViewController = hc

        // Menu Bar Companion
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupHotKeysAndMonitors()
        updateMenuBarMenu()
        observeContentFittingSize()

        // Prompt accessibility system dialog if not trusted
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            let promptOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOpts)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: NSNotification.Name("OpenSettings"),
            object: nil
        )
        handleAppDidBecomeActive()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(isPresented: Binding(
                get: { [weak self] in self?.settingsWindow?.isVisible ?? false },
                set: { [weak self] isPres in
                    if !isPres {
                        self?.settingsWindow?.orderOut(nil)
                    }
                }
            ), onKeySaved: { [weak self] in
                self?.viewModel.refreshApiKey()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "LingoBar Settings"
            window.center()
            window.contentView = NSHostingView(rootView: settingsView)
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateMenuBarMenu() {
        guard let button = statusItem?.button else { return }

        button.title = ""

        let menu = NSMenu()
        let translateItem = NSMenuItem(title: "Translate Selection", action: #selector(triggerFromMenu), keyEquivalent: "")

        if !viewModel.hotKeyConflictMessage.isEmpty {
            let conflictIcon = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "LingoBar - Shortcut Conflict: Click to Translate")
            conflictIcon?.isTemplate = true
            button.image = conflictIcon
            button.toolTip = "LingoBar - Shortcut Conflict: Click to Translate"

            let conflictItem = NSMenuItem(title: "⚠️ Shortcut Conflict: Use Menu to Translate", action: nil, keyEquivalent: "")
            conflictItem.isEnabled = false
            menu.addItem(conflictItem)
            menu.addItem(NSMenuItem.separator())

            translateItem.keyEquivalent = ""
            translateItem.keyEquivalentModifierMask = []
        } else {
            let normalIcon = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "LingoBar")
            normalIcon?.isTemplate = true
            button.image = normalIcon
            button.toolTip = "LingoBar - Option+Space"

            translateItem.keyEquivalent = " "
            translateItem.keyEquivalentModifierMask = [.option]
        }

        menu.addItem(translateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit LingoBar", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        GlobalHotKeyManager.shared.teardown()
        teardownMonitors()
        viewModel.cleanup()
    }

    @objc private func handleAppDidBecomeActive() {
        let isTrusted = AXIsProcessTrustedWithOptions(nil)
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.isAccessibilityTrusted = isTrusted
        }
    }

    @objc func triggerFromMenu() {
        triggerInstantAction()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func setupHotKeysAndMonitors() {
        // 1. Native Carbon Hotkey Manager (Intercepts Option+Space and Option+Shift+L globally)
        GlobalHotKeyManager.shared.onTrigger = { [weak self] in
            self?.triggerInstantAction()
        }
        let hotKeySuccess = GlobalHotKeyManager.shared.setup()
        if !hotKeySuccess {
            viewModel.hotKeyConflictMessage = "Global shortcut conflicted with another application. Click menu bar icon or reassign."
        } else {
            viewModel.hotKeyConflictMessage = ""
        }

        // 2. Global Hotkey Monitor as secondary backup
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (flags == [.option, .shift] && event.keyCode == 37) ||
               (flags == [.option] && event.keyCode == 49) {
                DispatchQueue.main.async {
                    self?.triggerInstantAction()
                }
            } else if event.keyCode == 53 && (self?.panel.isVisible == true) { // Esc key
                DispatchQueue.main.async {
                    self?.dismissPopover()
                }
            }
        }

        // 3. Local Monitor for events when LingoBar is foregrounded
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 && (self?.panel.isVisible == true) { // Esc key
                self?.dismissPopover()
                return nil
            }
            return event
        }

        // 4. Global Mouse Down Monitor to dismiss when clicking outside
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return }
            let clickLocation = NSEvent.mouseLocation
            if !self.panel.frame.contains(clickLocation) {
                DispatchQueue.main.async {
                    self.dismissPopover()
                }
            }
        }

        // 5. Global Scroll Monitor to dismiss on page / window scroll
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            DispatchQueue.main.async {
                self.dismissPopover()
            }
        }
    }

    private func teardownMonitors() {
        if let gkm = globalKeyDownMonitor {
            NSEvent.removeMonitor(gkm)
            globalKeyDownMonitor = nil
        }
        if let lkm = localKeyDownMonitor {
            NSEvent.removeMonitor(lkm)
            localKeyDownMonitor = nil
        }
        if let gmm = globalMouseDownMonitor {
            NSEvent.removeMonitor(gmm)
            globalMouseDownMonitor = nil
        }
        if let gsm = globalScrollMonitor {
            NSEvent.removeMonitor(gsm)
            globalScrollMonitor = nil
        }
    }

    private func observeContentFittingSize() {
        // Dynamically adjust popover frame height smoothly as content streams in
        viewModel.$outputText
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$isTruncated
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$hadStreamParseError
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$isManualInputMode
            .sink { [weak self] isManual in
                self?.panel.allowKeyForInput = isManual
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$isAccessibilityTrusted
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        viewModel.$hotKeyConflictMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
                self?.updateMenuBarMenu()
            }
            .store(in: &cancellables)
    }

    private func updatePopoverSize() {
        guard panel.isVisible, let hc = hostingController, let anchor = currentAnchorRect else { return }
        let fitting = hc.sizeThatFits(in: CGSize(width: 340, height: 320))
        let targetHeight = min(max(fitting.height, 120), 280)
        let newSize = NSSize(width: 340, height: targetHeight)
        
        if abs(panel.frame.height - newSize.height) > 2 {
            positionPanel(anchoredTo: anchor, desiredHeight: newSize.height)
        }
    }

    func dismissPopover() {
        guard panel.isVisible else { return }
        panel.allowKeyForInput = false
        panel.orderOut(nil)
        currentAnchorRect = nil
        viewModel.resetToEmptyState()
    }

    func triggerInstantAction() {
        if panel.isVisible {
            dismissPopover()
            return
        }

        // 1. Check Accessibility permissions and prompt system dialog if not trusted
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            let promptOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOpts)
        }
        viewModel.isAccessibilityTrusted = isTrusted

        let captureResult = captureSelectedTextAndBounds()
        currentAnchorRect = captureResult.bounds

        viewModel.resetToEmptyState()
        viewModel.isAccessibilityTrusted = isTrusted

        if let text = captureResult.text, !text.isEmpty {
            // Selected text found: automatic streaming translation
            viewModel.isManualInputMode = false
            panel.allowKeyForInput = false
            viewModel.inputText = text

            positionPanel(anchoredTo: captureResult.bounds, desiredHeight: 140)
            panel.orderFrontRegardless()
            viewModel.runTranslate()
        } else {
            // No selection found: open inline pill with manual input field at cursor
            viewModel.isManualInputMode = true
            panel.allowKeyForInput = true

            positionPanel(anchoredTo: captureResult.bounds, desiredHeight: 140)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Positions the popover panel above or below the selection bounds clamped to the current screen
    private func positionPanel(anchoredTo targetRect: NSRect, desiredHeight: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetRect) }) ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelWidth: CGFloat = 340
        let panelHeight: CGFloat = desiredHeight
        let margin: CGFloat = 8

        // Try placing below selection first
        var originX = targetRect.origin.x + (targetRect.width - panelWidth) / 2.0
        var originY = targetRect.origin.y - panelHeight - margin

        // If below screen bottom edge, place above the selection
        if originY < visibleFrame.minY {
            originY = targetRect.origin.y + targetRect.height + margin
        }

        // Horizontal clamping within visible screen bounds
        if originX < visibleFrame.minX + margin {
            originX = visibleFrame.minX + margin
        } else if originX + panelWidth > visibleFrame.maxX - margin {
            originX = visibleFrame.maxX - panelWidth - margin
        }

        // Vertical clamping
        if originY + panelHeight > visibleFrame.maxY - margin {
            originY = visibleFrame.maxY - panelHeight - margin
        }
        if originY < visibleFrame.minY + margin {
            originY = visibleFrame.minY + margin
        }

        panel.setFrame(NSRect(x: round(originX), y: round(originY), width: panelWidth, height: panelHeight), display: true, animate: false)
    }

    /// Captures selected text and converts its AX screen bounds to AppKit desktop coordinates
    private func captureSelectedTextAndBounds() -> (text: String?, bounds: NSRect) {
        let mouseLocation = NSEvent.mouseLocation
        let fallbackRect = NSRect(x: mouseLocation.x - 10, y: mouseLocation.y - 10, width: 20, height: 20)

        let systemWide = AXUIElementCreateSystemWide()

        // 1. Try focused application -> focused UI element
        var focusedElement: AXUIElement?
        var focusedApp: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let app = focusedApp {
            var focusedUIElement: AnyObject?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedUIElement) == .success,
               let elem = focusedUIElement {
                focusedElement = (elem as! AXUIElement)
            }
        }

        // 2. Try system-wide focused UI element directly
        if focusedElement == nil {
            var directElem: AnyObject?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &directElem) == .success,
               let elem = directElem {
                focusedElement = (elem as! AXUIElement)
            }
        }

        var selectedText: String? = nil
        var calculatedBounds: NSRect? = nil

        if let elem = focusedElement {
            // Helper to extract text from a single element
            func extractText(from targetElem: AXUIElement) -> String? {
                // 1. Direct kAXSelectedTextAttribute
                var selectedTextValue: AnyObject?
                if AXUIElementCopyAttributeValue(targetElem, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
                   let text = selectedTextValue as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }

                // 2. Range-based extraction
                var selectedRangeVal: AnyObject?
                let rangeResult = AXUIElementCopyAttributeValue(targetElem, kAXSelectedTextRangeAttribute as CFString, &selectedRangeVal)
                if rangeResult == .success, let rangeAX = selectedRangeVal, CFGetTypeID(rangeAX) == AXValueGetTypeID() {
                    let axRange = rangeAX as! AXValue

                    // Parameterized string for range (Safari, WebKit, Pages, TextEdit)
                    var strVal: AnyObject?
                    let strResult = AXUIElementCopyParameterizedAttributeValue(
                        targetElem,
                        kAXStringForRangeParameterizedAttribute as CFString,
                        axRange,
                        &strVal
                    )
                    if strResult == .success, let text = strVal as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }

                    // Sliced kAXValueAttribute (Chromium, TextFields, Electron)
                    var cfRange = CFRange()
                    if AXValueGetValue(axRange, .cfRange, &cfRange) && cfRange.length > 0 {
                        var valAttr: AnyObject?
                        if AXUIElementCopyAttributeValue(targetElem, kAXValueAttribute as CFString, &valAttr) == .success {
                            let rawString = (valAttr as? String) ?? ((valAttr as? NSAttributedString)?.string)
                            if let fullText = rawString {
                                let nsString = fullText as NSString
                                if cfRange.location >= 0 && cfRange.location + cfRange.length <= nsString.length {
                                    let sub = nsString.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
                                    let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        return trimmed
                                    }
                                }
                            }
                        }
                    }
                }

                return nil
            }

            // Attempt extraction on focused element
            selectedText = extractText(from: elem)

            // Extract bounds from focused element if available
            var selectedRangeVal: AnyObject?
            let rangeResult = AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &selectedRangeVal)
            if rangeResult == .success, let rangeAX = selectedRangeVal, CFGetTypeID(rangeAX) == AXValueGetTypeID() {
                var boundsVal: AnyObject?
                let boundsResult = AXUIElementCopyParameterizedAttributeValue(
                    elem,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeAX as! AXValue,
                    &boundsVal
                )
                if boundsResult == .success, let bVal = boundsVal, CFGetTypeID(bVal) == AXValueGetTypeID() {
                    var axRect = CGRect.zero
                    if AXValueGetValue(bVal as! AXValue, .cgRect, &axRect) && axRect.width > 0 && axRect.height > 0 {
                        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                        let appKitY = primaryScreenHeight - axRect.origin.y - axRect.height
                        calculatedBounds = NSRect(x: axRect.origin.x, y: appKitY, width: axRect.width, height: axRect.height)
                    }
                }
            }

            // Traverse up to 3 parent levels if text still not found (common in web views / compound controls)
            if selectedText == nil {
                var currentElem = elem
                for _ in 0..<3 {
                    var parentVal: AnyObject?
                    if AXUIElementCopyAttributeValue(currentElem, kAXParentAttribute as CFString, &parentVal) == .success,
                       let parent = parentVal {
                        let parentElem = parent as! AXUIElement
                        if let parentText = extractText(from: parentElem) {
                            selectedText = parentText
                            break
                        }
                        currentElem = parentElem
                    } else {
                        break
                    }
                }
            }
        }

        // Fallback: Universal Synthetic Cmd+C Copy when AX APIs do not expose selection
        if selectedText == nil || selectedText!.isEmpty {
            if let copied = copySelectedTextViaSyntheticCommandC() {
                selectedText = copied
            }
        }

        return (selectedText, calculatedBounds ?? fallbackRect)
    }

    /// Universal fallback: simulates Cmd+C to capture highlighted text when Accessibility APIs do not expose selection.
    private func copySelectedTextViaSyntheticCommandC() -> String? {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // kVK_ANSI_C

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) else {
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Poll pasteboard for up to 150ms (15 iterations x 10ms)
        var copiedString: String? = nil
        for _ in 0..<15 {
            usleep(10_000)
            if pasteboard.changeCount != initialChangeCount {
                if let str = pasteboard.string(forType: .string) {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        copiedString = trimmed
                    }
                }
                break
            }
        }

        return copiedString
    }
}

// MARK: - Popover View Model with Robust Multibyte UTF-8 Streaming & Error Handling
class PopoverViewModel: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    @Published var copied: Bool = false
    @Published var isTruncated: Bool = false
    @Published var hadStreamParseError: Bool = false
    @Published var isManualInputMode: Bool = false
    @Published var isAccessibilityTrusted: Bool = true
    @Published var hotKeyConflictMessage: String = ""

    @Published var apiKey: String = ""
    @Published var activeProvider: AIProvider = AIProvider.current
    @Published var storageError: String = ""
    @Published var fallbackWarning: String = ""
    @Published var loadingPlaceholder: String = "Translating to spoken Sinhala..."

    private var requestProvider: AIProvider = AIProvider.current
    private var session: URLSession!
    private var currentTask: URLSessionDataTask?
    private var currentRequestId: UUID = UUID()
    private var isTaskInFlight: Bool = false
    private var streamDataBuffer = Data()
    private var errorDataBuffer = Data()
    private var dismissWorkItem: DispatchWorkItem?
    private var responseStatusCode: Int = 200
    private var isEventStream: Bool = false
    private var receivedDone: Bool = false

    override init() {
        super.init()
        do {
            try KeychainHelper.shared.migrateLegacyKeyIfNeeded()
            let provider = AIProvider.current
            self.activeProvider = provider
            self.requestProvider = provider
            self.apiKey = (try KeychainHelper.shared.getKey(account: provider.keychainAccount)) ?? ""
            self.fallbackWarning = (provider == .groq) ? (KeychainHelper.shared.fallbackRecoveryWarning ?? "") : ""
        } catch {
            self.storageError = "Keychain error: \(error.localizedDescription)"
            self.apiKey = ""
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20.0
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }

    func cancelInFlightTask() {
        // Invalidate request ID first so any queued or concurrent delegate callbacks fail the match guard immediately
        currentRequestId = UUID()
        if isTaskInFlight || currentTask != nil {
            currentTask?.cancel()
            currentTask = nil
            isTaskInFlight = false
        }
        isLoading = false
        streamDataBuffer.removeAll()
        errorDataBuffer.removeAll()
    }

    func refreshApiKey() {
        DispatchQueue.main.async {
            let previousProvider = self.activeProvider
            let provider = AIProvider.current
            self.activeProvider = provider

            if previousProvider != provider {
                self.cancelInFlightTask()
            }

            do {
                self.apiKey = (try KeychainHelper.shared.getKey(account: provider.keychainAccount)) ?? ""
                self.fallbackWarning = (provider == .groq) ? (KeychainHelper.shared.fallbackRecoveryWarning ?? "") : ""
                self.storageError = ""
                if self.errorMessage.contains("API Key") {
                    self.errorMessage = ""
                }
            } catch {
                self.storageError = "Keychain error: \(error.localizedDescription)"
                self.apiKey = ""
            }
        }
    }

    func cleanup() {
        resetToEmptyState()
        session?.invalidateAndCancel()
    }

    func resetToEmptyState() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        cancelInFlightTask()
        responseStatusCode = 200
        isEventStream = false
        receivedDone = false
        hadStreamParseError = false
        inputText = ""
        outputText = ""
        errorMessage = ""
        copied = false
        isTruncated = false
        isManualInputMode = false
    }

    func runTranslate() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        cancelInFlightTask()

        let provider = AIProvider.current
        self.activeProvider = provider
        self.requestProvider = provider
        self.loadingPlaceholder = "Translating to spoken Sinhala..."

        let key: String
        do {
            guard let retrieved = try KeychainHelper.shared.getKey(account: provider.keychainAccount), !retrieved.isEmpty else {
                self.apiKey = ""
                self.errorMessage = "\(provider.displayName) API Key not configured. Please open Settings (⌘,) to configure."
                return
            }
            key = retrieved
            self.apiKey = retrieved
        } catch {
            self.apiKey = ""
            self.errorMessage = "Keychain error accessing \(provider.displayName) API Key: \(error.localizedDescription)"
            return
        }

        let model = provider.selectedModel
        let url = provider.chatEndpoint

        let requestId = UUID()
        currentRequestId = requestId
        isLoading = true
        isTaskInFlight = true
        errorMessage = ""
        outputText = ""
        copied = false
        isTruncated = false
        hadStreamParseError = false
        responseStatusCode = 200
        isEventStream = false
        receivedDone = false
        streamDataBuffer.removeAll()
        errorDataBuffer.removeAll()

        let prompt = """
        You are an expert English-to-Sinhala translator focused on zero-friction natural clarity.
        Translate the following English text into simple, everyday, colloquial spoken-style Sinhala (සරල එදිනෙදා සිංහල).
        Strict Guidelines:
        - Output ONLY the Sinhala translation.
        - Do NOT include any English explanations, phonetic transcriptions, notes, or greetings.
        - Avoid archaic, overly formal dictionary literature words. Use natural spoken Sri Lankan idiom.

        Text to translate:
        \"\"\"\(inputText)\"\"\"
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 1024,
            "stream": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request)
        task.taskDescription = requestId.uuidString
        self.currentTask = task
        task.resume()
    }

    func runPolish(tone: String = "natural") {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        cancelInFlightTask()

        let provider = AIProvider.current
        self.activeProvider = provider
        self.requestProvider = provider
        self.loadingPlaceholder = "Polishing text (\(tone))..."

        let key: String
        do {
            guard let retrieved = try KeychainHelper.shared.getKey(account: provider.keychainAccount), !retrieved.isEmpty else {
                self.apiKey = ""
                self.errorMessage = "\(provider.displayName) API Key not configured. Please open Settings (⌘,) to configure."
                return
            }
            key = retrieved
            self.apiKey = retrieved
        } catch {
            self.apiKey = ""
            self.errorMessage = "Keychain error accessing \(provider.displayName) API Key: \(error.localizedDescription)"
            return
        }

        let model = provider.selectedModel
        let url = provider.chatEndpoint

        let requestId = UUID()
        currentRequestId = requestId
        isLoading = true
        isTaskInFlight = true
        errorMessage = ""
        outputText = ""
        copied = false
        isTruncated = false
        hadStreamParseError = false
        responseStatusCode = 200
        isEventStream = false
        receivedDone = false
        streamDataBuffer.removeAll()
        errorDataBuffer.removeAll()

        let prompt = """
        You are an expert English writing assistant and editor.
        Polish and refine the following text for \(tone) clarity, grammar, and natural flow.
        Strict Guidelines:
        - Output ONLY the polished text.
        - Do NOT include any explanations, greetings, quotes, or notes.
        - Preserve the original meaning and tone while making it fluent and error-free.

        Text to polish:
        \"\"\"\(inputText)\"\"\"
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 1024,
            "stream": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request)
        task.taskDescription = requestId.uuidString
        self.currentTask = task
        task.resume()
    }

    func copyAndDismiss(onDismiss: @escaping () -> Void) {
        guard !outputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        copied = true

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissWorkItem = nil
            onDismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    // MARK: - URLSessionDataDelegate (HTTP Status & Multibyte UTF-8 SSE Streaming)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let taskDesc = dataTask.taskDescription, taskDesc == currentRequestId.uuidString else {
            completionHandler(.cancel)
            return
        }

        if let httpResponse = response as? HTTPURLResponse {
            let code = httpResponse.statusCode
            self.responseStatusCode = code

            if let mime = httpResponse.mimeType?.lowercased() {
                self.isEventStream = mime.contains("text/event-stream")
            } else if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
                self.isEventStream = contentType.lowercased().contains("text/event-stream")
            }

            if !(200...299).contains(code) {
                // Non-2xx HTTP error status
                self.isLoading = false
                let name = self.requestProvider.displayName
                switch code {
                case 401:
                    self.errorMessage = "\(name) API error (401): Invalid or unauthorized API key."
                case 429:
                    self.errorMessage = "\(name) API error (429): Rate limit or quota exceeded. Try again shortly."
                default:
                    self.errorMessage = "\(name) API error (\(code)): Unable to complete request."
                }
            } else if !self.isEventStream {
                // 2xx status but not streaming response: cancel task immediately to stop data receipt
                let name = self.requestProvider.displayName
                self.errorMessage = "\(name) API error: Unexpected non-streaming response."
                self.cancelInFlightTask()
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let taskDesc = dataTask.taskDescription, taskDesc == currentRequestId.uuidString else {
            return
        }

        // If non-2xx status, accumulate complete error response body (capped at 64KB)
        if !(200...299).contains(responseStatusCode) {
            let maxErrorBufferSize = 64 * 1024
            if errorDataBuffer.count < maxErrorBufferSize {
                let remainingSpace = maxErrorBufferSize - errorDataBuffer.count
                let slice = data.prefix(remainingSpace)
                errorDataBuffer.append(slice)
            }
            return
        }

        // Multibyte-safe UTF-8 buffering: accumulate bytes and only decode complete lines at '\n'
        streamDataBuffer.append(data)

        let maxStreamBufferSize = 128 * 1024 // 128KB
        let newlineByte: UInt8 = 0x0A // \n
        while let newlineIndex = streamDataBuffer.firstIndex(of: newlineByte) {
            let lineData = streamDataBuffer.subdata(in: 0..<newlineIndex)
            streamDataBuffer.removeSubrange(0...newlineIndex)

            // Check individual line size limit before decoding
            if lineData.count > maxStreamBufferSize {
                self.errorMessage = "Line exceeded maximum allowed size."
                self.cancelInFlightTask()
                return
            }

            // Safely decode the completed line chunk
            guard let lineStr = String(data: lineData, encoding: .utf8) else {
                self.hadStreamParseError = true
                continue
            }

            processSSELine(lineStr)
        }

        // Check remaining tail buffer size after draining all complete lines
        if streamDataBuffer.count > maxStreamBufferSize {
            self.errorMessage = "Stream buffer tail exceeded maximum allowed size."
            self.cancelInFlightTask()
            return
        }
    }

    private func processSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix(":") { return }

        if trimmed == "data: [DONE]" {
            self.receivedDone = true
            self.isLoading = false
            return
        }

        if trimmed.hasPrefix("data: ") {
            let jsonStr = String(trimmed.dropFirst(6))
            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                self.hadStreamParseError = true
                return
            }

            // Check for API-level error returned within stream
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                let code = errorObj["code"] as? String
                let name = self.requestProvider.displayName
                if code == "insufficient_quota" || msg.lowercased().contains("quota") {
                    let billingUrl = (self.requestProvider == .openAI) ? "platform.openai.com/account/billing" : "console.groq.com"
                    self.errorMessage = "\(name) API error: You have exceeded your account quota. Check billing at \(billingUrl)."
                } else {
                    self.errorMessage = "\(name) API error: \(msg)"
                }
                self.cancelInFlightTask()
                return
            }

            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                if let finishReason = first["finish_reason"] as? String, finishReason == "length" {
                    self.isTruncated = true
                }

                if let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    self.outputText.append(content)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskDesc = task.taskDescription, taskDesc == currentRequestId.uuidString else {
            return
        }

        self.isTaskInFlight = false
        self.currentTask = nil
        self.isLoading = false

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            self.errorMessage = error.localizedDescription
            return
        }

        // If non-2xx status, parse the accumulated complete JSON error body
        if !(200...299).contains(responseStatusCode) {
            let name = self.requestProvider.displayName
            if !errorDataBuffer.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: errorDataBuffer) as? [String: Any],
               let errorObj = json["error"] as? [String: Any] {
                let code = errorObj["code"] as? String
                let msg = errorObj["message"] as? String ?? "Unable to complete request."
                if code == "insufficient_quota" || msg.lowercased().contains("quota") {
                    let billingUrl = (self.requestProvider == .openAI) ? "platform.openai.com/account/billing" : "console.groq.com"
                    self.errorMessage = "\(name) API error: You have exceeded your account quota. Check billing at \(billingUrl)."
                } else {
                    self.errorMessage = "\(name) API error (\(responseStatusCode)): \(msg)"
                }
            }
            errorDataBuffer.removeAll()
            return
        }

        // Flush any trailing line in buffer
        if !streamDataBuffer.isEmpty {
            if let trailingStr = String(data: streamDataBuffer, encoding: .utf8) {
                processSSELine(trailingStr)
            } else {
                self.hadStreamParseError = true
            }
            streamDataBuffer.removeAll()
        }

        // Validate stream completeness for successful HTTP responses
        if (200...299).contains(responseStatusCode) && errorMessage.isEmpty {
            if outputText.isEmpty {
                self.errorMessage = "Stream completed with empty output."
            } else if !receivedDone {
                self.errorMessage = "Stream interrupted before completion."
            }
        }
    }
}

// MARK: - Native Tooltip / Popover Bubble UI with Dynamic Sizing & Scrollable Content
struct InlinePopoverView: View {
    @ObservedObject var vm: PopoverViewModel
    var onClose: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header Row: Status & Actions
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "character.book.closed.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 11))
                    Text("LingoBar")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary.opacity(0.85))
                }

                Spacer()

                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                if !vm.outputText.isEmpty {
                    Button(action: {
                        vm.copyAndDismiss(onDismiss: onClose)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: vm.copied ? "checkmark.circle.fill" : "doc.on.doc")
                            Text(vm.copied ? "Copied" : "Copy")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(vm.copied ? .green : .blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            // API Key Not Configured Banner
            if vm.apiKey.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(vm.activeProvider.displayName) API Key not configured.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.orange)
                        Button("Configure in Settings (⌘,)") {
                            NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                    }
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            // Accessibility Permission Banner (shown when AX permission is missing)
            if !vm.isAccessibilityTrusted {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility permission needed to auto-read highlighted text.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.orange)
                        Button("Open Privacy & Security > Accessibility") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                vm.isAccessibilityTrusted = AXIsProcessTrustedWithOptions(nil)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                    }
                }
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            // Global Hotkey Conflict Banner
            if !vm.hotKeyConflictMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    Text(vm.hotKeyConflictMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.8))
                }
                .padding(4)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(4)
            }

            // Manual Input Mode (shown when no text was selected)
            if vm.isManualInputMode && vm.outputText.isEmpty && !vm.isLoading {
                HStack(spacing: 6) {
                    TextField("Type English text to translate...", text: $vm.inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(6)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                        .focused($isFieldFocused)
                        .onSubmit {
                            vm.runTranslate()
                        }

                    Button(action: {
                        vm.runTranslate()
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFieldFocused = true
                    }
                }
            }

            // Translation Content with Smooth ScrollView & Dynamic Clamped Height
            if !vm.outputText.isEmpty || vm.isLoading || !vm.errorMessage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !vm.errorMessage.isEmpty {
                        Text(vm.errorMessage)
                            .font(.system(size: 11.5))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if vm.outputText.isEmpty && vm.isLoading {
                        Text(vm.loadingPlaceholder)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(vm.outputText)
                                .font(.system(size: 13.5, weight: .medium))
                                .lineSpacing(3)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !vm.outputText.isEmpty {
                        vm.copyAndDismiss(onDismiss: onClose)
                    }
                }
            }

            // Truncation Warning Banner (if hit length limit)
            if vm.isTruncated {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 9.5))
                    Text("Output truncated due to token limit")
                        .font(.system(size: 9.5))
                        .foregroundColor(.orange)
                }
            }

            // Stream Parse Warning Banner (if corrupt chunks encountered)
            if vm.hadStreamParseError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 9.5))
                    Text("Warning: Stream encountered malformed data")
                        .font(.system(size: 9.5))
                        .foregroundColor(.yellow)
                }
            }

            // Subdued Hint
            HStack {
                Text(vm.isManualInputMode && vm.outputText.isEmpty ? "Press ↵ to translate • Esc to dismiss" : "Click to copy • Esc to dismiss")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(
            ZStack {
                VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                Color(NSColor.windowBackgroundColor).opacity(0.65)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 5)
        .onAppear {
            vm.isAccessibilityTrusted = AXIsProcessTrustedWithOptions(nil)
        }
    }
}

// MARK: - Native Liquid Glass Blur View
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
