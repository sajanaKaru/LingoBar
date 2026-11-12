import SwiftUI
import AppKit
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

// MARK: - Floating Panel (Liquid Glass HUD)
class FloatingPanel: NSPanel {
    init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: backing,
            defer: flag
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.hasShadow = true
    }

    override var canBecomeKey: Bool {
        return true
    }
}

// MARK: - App Delegate & Global Hotkey / Event Orchestration
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem?
    var viewModel = AppViewModel()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = MainContentView(vm: viewModel, onClose: { [weak self] in
            self?.dismissHUD()
        })

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 390),
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: contentView)
        panel.center()

        // Menu Bar Companion
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🇱🇰 LingoBar"
            button.action = #selector(toggleHUD)
            button.target = self
        }

        // Global Hotkey Monitor (Option + Space OR Option + Shift + L)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (flags == [.option, .shift] && event.keyCode == 37) ||
               (flags == [.option] && event.keyCode == 49) {
                self?.triggerInstantAction()
            }
        }

        // Local Monitor for when the app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismissHUD()
                return nil
            }
            return event
        }
    }

    @objc func toggleHUD() {
        if panel.isVisible {
            dismissHUD()
        } else {
            triggerInstantAction()
        }
    }

    func dismissHUD() {
        panel.orderOut(nil)
        viewModel.resetToEmptyState()
    }

    func triggerInstantAction() {
        if panel.isVisible {
            dismissHUD()
            return
        }

        // Strictly capture selected text via Accessibility API (no clipboard fallback)
        if let axText = captureSelectedTextViaAccessibility(), !axText.isEmpty {
            viewModel.resetToEmptyState()
            viewModel.inputText = axText
            viewModel.runTranslate()
        } else {
            // Clean empty state when no text selected or AX is unavailable
            viewModel.resetToEmptyState()
        }

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Captures selected text strictly via macOS Accessibility API without touching the system clipboard
    private func captureSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard appResult == .success, let app = focusedApp else { return nil }

        var focusedUIElement: AnyObject?
        let elemResult = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedUIElement)
        guard elemResult == .success, let element = focusedUIElement else { return nil }

        var selectedTextValue: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        guard textResult == .success, let text = selectedTextValue as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - View Model & Groq Engine with Request Generation Guards
enum AppTab {
    case translate
    case polish
}

class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .translate
    @Published var inputText: String = "" {
        didSet {
            if inputText != oldValue {
                dismissWorkItem?.cancel()
                dismissWorkItem = nil
                copied = false
            }
        }
    }
    @Published var outputText: String = ""
    @Published var warningMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    @Published var copied: Bool = false
    @Published var polishTone: String = "Natural"

    private let apiKey: String
    private var currentTask: URLSessionDataTask?
    private var currentRequestId: UUID = UUID()
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        let keyPath = "/Users/sajanakarunarathna/Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY"
        if let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            self.apiKey = key
        } else {
            self.apiKey = ""
        }
    }

    func resetToEmptyState() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentTask?.cancel()
        currentTask = nil
        currentRequestId = UUID()
        isLoading = false
        inputText = ""
        outputText = ""
        warningMessage = ""
        errorMessage = ""
        copied = false
    }

    func runTranslate() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        selectedTab = .translate
        isLoading = true
        errorMessage = ""
        warningMessage = ""
        outputText = ""
        copied = false

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

        callGroq(prompt: prompt)
    }

    func runPolish() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        selectedTab = .polish
        isLoading = true
        errorMessage = ""
        warningMessage = ""
        outputText = ""
        copied = false

        let prompt = """
        You are an elite English writing assistant and copy editor.
        Rewrite and polish the following English text so that it is grammatically flawless, natural, and matches a \(polishTone.lowercased()) tone.
        Strict Guidelines:
        - Output ONLY the polished English text.
        - Do NOT add explanations, introductory text, quotation marks, or conversational filler.
        - Retain the exact original intent and key nuances.

        Text to polish:
        \"\"\"\(inputText)\"\"\"
        """

        callGroq(prompt: prompt)
    }

    private func callGroq(prompt: String) {
        currentTask?.cancel()
        let requestId = UUID()
        currentRequestId = requestId

        guard !apiKey.isEmpty else {
            self.isLoading = false
            self.errorMessage = "Groq API Key not found in Vault."
            return
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { return }

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
            "max_tokens": 2048
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.currentRequestId == requestId else {
                    return // Ignore responses from cancelled / outdated requests
                }
                self.isLoading = false

                if let error = error as NSError?, error.code == NSURLErrorCancelled {
                    return
                }

                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let data = data else {
                    self.errorMessage = "No response data received."
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                            self.errorMessage = msg
                            return
                        }

                        if let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first {
                            let finishReason = first["finish_reason"] as? String
                            if let message = first["message"] as? [String: Any],
                               let content = message["content"] as? String {
                                self.outputText = content.trimmingCharacters(in: .whitespacesAndNewlines)
                                if finishReason == "length" {
                                    self.warningMessage = "Output truncated due to token limit."
                                }
                                return
                            }
                        }
                    }
                    self.errorMessage = "Invalid response format from Groq."
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        currentTask?.resume()
    }

    func copyOutputAndDismiss(onDismiss: @escaping () -> Void) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
}

// MARK: - Liquid Glass UI Views
struct MainContentView: View {
    @ObservedObject var vm: AppViewModel
    var onClose: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text("🇱🇰")
                        .font(.system(size: 16))
                    Text("LingoBar")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("HUD")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.18))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("⌥Space / ⌥⇧L")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.8))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
            }

            // Tab Selector
            Picker("", selection: $vm.selectedTab) {
                Text("Translate (සිංහල)").tag(AppTab.translate)
                Text("Polish English").tag(AppTab.polish)
            }
            .pickerStyle(.segmented)

            // Tone Selector (Only when polish tab is selected)
            if vm.selectedTab == .polish {
                HStack {
                    Text("Tone:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $vm.polishTone) {
                        Text("Natural").tag("Natural")
                        Text("Professional").tag("Professional")
                        Text("Casual").tag("Casual")
                        Text("Concise").tag("Concise")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    Spacer()
                }
                .transition(.opacity)
            }

            // Input Area
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.selectedTab == .translate ? "English Input:" : "Draft Input:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !vm.inputText.isEmpty {
                        Button("Clear") {
                            vm.resetToEmptyState()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    }
                }

                TextEditor(text: $vm.inputText)
                    .font(.system(size: 13))
                    .frame(height: 72)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.85))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .focused($isInputFocused)
            }

            // Action / Run Button
            HStack {
                Text("⌘ ↵ to run")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))

                Spacer()

                Button(action: {
                    if vm.selectedTab == .translate {
                        vm.runTranslate()
                    } else {
                        vm.runPolish()
                    }
                }) {
                    HStack(spacing: 6) {
                        if vm.isLoading {
                            ProgressView().controlSize(.small)
                            Text("Processing...")
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Image(systemName: vm.selectedTab == .translate ? "character.book.closed" : "wand.and.stars")
                            Text(vm.selectedTab == .translate ? "Translate" : "Polish")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.isLoading || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Output Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(vm.selectedTab == .translate ? "Sinhala (සරල සිංහල):" : "Polished Result:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    Spacer()

                    if !vm.outputText.isEmpty {
                        Button(action: {
                            vm.copyOutputAndDismiss(onDismiss: onClose)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: vm.copied ? "checkmark.circle.fill" : "doc.on.doc")
                                Text(vm.copied ? "Copied & Closing" : "Copy & Close (↵)")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(vm.copied ? .green : .blue)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }

                ScrollView {
                    Text(vm.outputText.isEmpty ? (vm.isLoading ? "Translating with Groq AI..." : "Select text anywhere and hit ⌥Space to translate instantly.") : vm.outputText)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(4)
                        .foregroundColor(vm.outputText.isEmpty ? .secondary.opacity(0.8) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 90)
                .background(Color(NSColor.textBackgroundColor).opacity(0.85))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                if !vm.warningMessage.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(vm.warningMessage)
                            .foregroundColor(.orange)
                    }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                }

                if !vm.errorMessage.isEmpty {
                    Text("Error: \(vm.errorMessage)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 2)
                }
            }

            // Footer
            HStack {
                Button("Esc to close") {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Quit LingoBar") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(16)
        .frame(width: 500, height: 390)
        .background(VisualEffectView().cornerRadius(14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            if vm.inputText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if vm.inputText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFocused = true
                }
            }
        }
    }
}

// MARK: - Blur Visual Effect
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
