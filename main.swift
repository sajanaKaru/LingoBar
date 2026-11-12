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

// MARK: - Lightweight Non-Activating Inline Popover Panel
final class InlinePopoverPanel: NSPanel {
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
        return false
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
        if let button = statusItem?.button {
            button.title = "🇱🇰 LingoBar"
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Translate Selection (⌥Space)", action: #selector(triggerFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit LingoBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem?.menu = menu
        }

        setupMonitors()
        observeContentFittingSize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardownMonitors()
        viewModel.cleanup()
    }

    @objc func triggerFromMenu() {
        triggerInstantAction()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func setupMonitors() {
        // Global Hotkey Monitor (Option + Space OR Option + Shift + L)
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

        // Local Monitor for events when LingoBar is foregrounded
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 && (self?.panel.isVisible == true) { // Esc key
                self?.dismissPopover()
                return nil
            }
            return event
        }

        // Global Mouse Down Monitor to dismiss when clicking outside
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return }
            let clickLocation = NSEvent.mouseLocation
            if !self.panel.frame.contains(clickLocation) {
                DispatchQueue.main.async {
                    self.dismissPopover()
                }
            }
        }

        // Global Scroll Monitor to dismiss on page / window scroll
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
        panel.orderOut(nil)
        currentAnchorRect = nil
        viewModel.resetToEmptyState()
    }

    func triggerInstantAction() {
        if panel.isVisible {
            dismissPopover()
            return
        }

        // 1. Capture selected text and its bounding box strictly via Accessibility API
        let captureResult = captureSelectedTextAndBounds()
        guard let text = captureResult.text, !text.isEmpty else {
            NSSound.beep()
            return
        }

        viewModel.resetToEmptyState()
        viewModel.inputText = text
        currentAnchorRect = captureResult.bounds

        // 2. Initial position
        positionPanel(anchoredTo: captureResult.bounds, desiredHeight: 140)

        // 3. Show non-activating panel (preserves user selection highlight and active app)
        panel.orderFrontRegardless()

        // 4. Trigger streaming translation
        viewModel.runTranslate()
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
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard appResult == .success, let app = focusedApp else {
            return (nil, fallbackRect)
        }

        var focusedUIElement: AnyObject?
        let elemResult = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedUIElement)
        guard elemResult == .success, let element = focusedUIElement else {
            return (nil, fallbackRect)
        }

        var selectedTextValue: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        guard textResult == .success, let text = selectedTextValue as? String else {
            return (nil, fallbackRect)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, fallbackRect)
        }

        // Attempt to extract exact screen bounds for selected text range
        var selectedRangeVal: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeVal)

        if rangeResult == .success, let rangeAX = selectedRangeVal, CFGetTypeID(rangeAX) == AXValueGetTypeID() {
            var boundsVal: AnyObject?
            let boundsResult = AXUIElementCopyParameterizedAttributeValue(
                element as! AXUIElement,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeAX as! AXValue,
                &boundsVal
            )

            if boundsResult == .success, let bVal = boundsVal, CFGetTypeID(bVal) == AXValueGetTypeID() {
                var axRect = CGRect.zero
                if AXValueGetValue(bVal as! AXValue, .cgRect, &axRect) && axRect.width > 0 && axRect.height > 0 {
                    // Convert AX top-left coordinates to AppKit bottom-left desktop coordinates
                    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                    let appKitY = primaryScreenHeight - axRect.origin.y - axRect.height
                    let appKitRect = NSRect(x: axRect.origin.x, y: appKitY, width: axRect.width, height: axRect.height)
                    return (trimmed, appKitRect)
                }
            }
        }

        // Fallback to mouse location if range bounds are unsupported by the targeted app
        return (trimmed, fallbackRect)
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

    private let apiKey: String
    private var session: URLSession!
    private var currentTask: URLSessionDataTask?
    private var currentRequestId: UUID = UUID()
    private var streamDataBuffer = Data()
    private var dismissWorkItem: DispatchWorkItem?
    private var responseStatusCode: Int = 200
    private var isEventStream: Bool = false
    private var receivedDone: Bool = false

    override init() {
        let keyPath = "/Users/sajanakarunarathna/Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY"
        if let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            self.apiKey = key
        } else {
            self.apiKey = ""
        }
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20.0
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }

    func cleanup() {
        resetToEmptyState()
        session?.invalidateAndCancel()
    }

    func resetToEmptyState() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentTask?.cancel()
        currentTask = nil
        currentRequestId = UUID()
        streamDataBuffer.removeAll()
        responseStatusCode = 200
        isEventStream = false
        receivedDone = false
        isLoading = false
        inputText = ""
        outputText = ""
        errorMessage = ""
        copied = false
        isTruncated = false
    }

    func runTranslate() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentTask?.cancel()

        let requestId = UUID()
        currentRequestId = requestId
        isLoading = true
        errorMessage = ""
        outputText = ""
        copied = false
        isTruncated = false
        responseStatusCode = 200
        isEventStream = false
        receivedDone = false
        streamDataBuffer.removeAll()

        guard !apiKey.isEmpty else {
            self.isLoading = false
            self.errorMessage = "Groq API Key not found in Vault."
            return
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            self.isLoading = false
            self.errorMessage = "Invalid API endpoint URL."
            return
        }

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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "openai/gpt-oss-120b",
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
                switch code {
                case 401:
                    self.errorMessage = "Groq API error (401): Invalid or unauthorized API key."
                case 429:
                    self.errorMessage = "Groq API error (429): Rate limit exceeded. Try again shortly."
                default:
                    self.errorMessage = "Groq API error (\(code)): Unable to complete translation."
                }
            } else if !self.isEventStream {
                // 2xx status but not streaming response
                self.errorMessage = "Groq API error: Unexpected non-streaming response."
                self.isLoading = false
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let taskDesc = dataTask.taskDescription, taskDesc == currentRequestId.uuidString else {
            return
        }

        // If non-2xx status, parse detailed JSON error message if provided by API
        if !(200...299).contains(responseStatusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                self.errorMessage = "Groq API error (\(responseStatusCode)): \(msg)"
            }
            return
        }

        // Multibyte-safe UTF-8 buffering: accumulate bytes and only decode complete lines at '\n'
        streamDataBuffer.append(data)

        let newlineByte: UInt8 = 0x0A // \n
        while let newlineIndex = streamDataBuffer.firstIndex(of: newlineByte) {
            let lineData = streamDataBuffer.subdata(in: 0..<newlineIndex)
            streamDataBuffer.removeSubrange(0...newlineIndex)

            // Safely decode the completed line chunk
            guard let lineStr = String(data: lineData, encoding: .utf8) else {
                continue
            }

            processSSELine(lineStr)
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
                return
            }

            // Check for API-level error returned within stream
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                self.errorMessage = msg
                self.isLoading = false
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

        self.isLoading = false

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            self.errorMessage = error.localizedDescription
            return
        }

        // Flush any trailing line in buffer
        if !streamDataBuffer.isEmpty {
            if let trailingStr = String(data: streamDataBuffer, encoding: .utf8) {
                processSSELine(trailingStr)
            }
            streamDataBuffer.removeAll()
        }

        // Validate stream completeness for successful HTTP responses
        if (200...299).contains(responseStatusCode) && errorMessage.isEmpty {
            if outputText.isEmpty {
                self.errorMessage = "Translation stream completed with empty output."
            } else if !receivedDone {
                self.errorMessage = "Translation stream interrupted before completion."
            }
        }
    }
}

// MARK: - Native Tooltip / Popover Bubble UI with Dynamic Sizing & Scrollable Content
struct InlinePopoverView: View {
    @ObservedObject var vm: PopoverViewModel
    var onClose: () -> Void

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

            // Translation Content with Smooth ScrollView & Dynamic Clamped Height
            VStack(alignment: .leading, spacing: 4) {
                if !vm.errorMessage.isEmpty {
                    Text(vm.errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if vm.outputText.isEmpty && vm.isLoading {
                    Text("Translating to spoken Sinhala...")
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

            // Subdued Hint
            HStack {
                Text("Click to copy • Esc to dismiss")
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
