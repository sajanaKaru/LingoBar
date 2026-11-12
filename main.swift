import SwiftUI
import AppKit
import Carbon

@main
struct LingoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class FloatingPanel: NSPanel {
    init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                   backing: backing,
                   defer: flag)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem?
    var viewModel = AppViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build floating panel
        let contentView = MainContentView(vm: viewModel, onClose: { [weak self] in
            self?.panel.orderOut(nil)
        })

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                              backing: .buffered,
                              defer: false)
        panel.contentViewController = NSHostingController(rootView: contentView)
        panel.center()

        // Menu bar indicator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🇱🇰 LingoBar"
            button.action = #selector(showApp)
            button.target = self
        }

        // Global hotkey: Option + Space or Option + Shift + L
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Option + Shift + L (keyCode 37) or Option + Space (keyCode 49)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (flags == [.option, .shift] && event.keyCode == 37) ||
               (flags == [.option] && event.keyCode == 49) {
                self?.triggerInstantAction()
            }
        }
    }

    @objc func showApp() {
        triggerInstantAction()
    }

    func triggerInstantAction() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        // 1. Simulate Command + C to copy whatever text is currently selected in any active app
        simulateCopy()

        // 2. Wait 80ms for clipboard to update, then read and translate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !clip.isEmpty {
                self.viewModel.inputText = clip
                self.viewModel.runTranslate()
            }
            self.panel.center()
            self.panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true) // 0x08 is 'c'
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

enum AppTab {
    case translate
    case polish
}

class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .translate
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    @Published var copied: Bool = false
    @Published var polishTone: String = "Natural"

    private let apiKey: String

    init() {
        let keyPath = "/Users/sajanakarunarathna/Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY"
        if let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            self.apiKey = key
        } else {
            self.apiKey = ""
        }
    }

    func runTranslate() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedTab = .translate
        isLoading = true
        errorMessage = ""
        outputText = ""

        let prompt = """
        You are a helpful English-to-Sinhala translator.
        Translate the following English text into simple, everyday, natural spoken-style Sinhala (සරල සිංහල).
        Do not use overly complex or archaic literature words.
        Output ONLY the Sinhala translation, without explanation or greetings.

        Text to translate:
        \"\"\"\(inputText)\"\"\"
        """

        callGroq(prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let text):
                    self?.outputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func runPolish() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedTab = .polish
        isLoading = true
        errorMessage = ""
        outputText = ""

        let prompt = """
        You are an expert English editor and proofreader.
        Rewrite and polish the following English text to make it grammatically correct, smooth, and \(polishTone.lowercased()).
        Correct any spelling, punctuation, or phrasing mistakes while preserving the exact intended meaning.
        Output ONLY the polished English sentence(s) with no quotation marks, preambles, or conversational filler.

        Text to polish:
        \"\"\"\(inputText)\"\"\"
        """

        callGroq(prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let text):
                    self?.outputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func callGroq(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "LingoBar", code: 401, userInfo: [NSLocalizedDescriptionKey: "Groq API Key not found."])))
            return
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": "qwen/qwen3.8-27b",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "LingoBar", code: 500, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                        completion(.failure(NSError(domain: "Groq", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])))
                        return
                    }

                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        completion(.success(content))
                        return
                    }
                }
                completion(.failure(NSError(domain: "LingoBar", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid API response structure"])))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.copied = false
        }
    }
}

struct MainContentView: View {
    @ObservedObject var vm: AppViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Header Bar
            HStack {
                Text("🇱🇰 LingoBar Instant")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("Shortcut: ⌥Space or ⌥⇧L")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }

            // Tab Switcher
            Picker("", selection: $vm.selectedTab) {
                Text("Translate (සරල සිංහල)").tag(AppTab.translate)
                Text("Polish English").tag(AppTab.polish)
            }
            .pickerStyle(.segmented)

            if vm.selectedTab == .polish {
                HStack {
                    Text("Tone:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $vm.polishTone) {
                        Text("Natural").tag("Natural")
                        Text("Professional").tag("Professional")
                        Text("Casual").tag("Casual")
                        Text("Concise").tag("Concise")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    Spacer()
                }
            }

            // Input
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.selectedTab == .translate ? "English Text:" : "Raw English Draft:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !vm.inputText.isEmpty {
                        Button("Clear") {
                            vm.inputText = ""
                            vm.outputText = ""
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }

                TextEditor(text: $vm.inputText)
                    .font(.system(size: 13))
                    .frame(height: 75)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
            }

            // Actions
            HStack {
                Spacer()
                Button(action: {
                    if vm.selectedTab == .translate {
                        vm.runTranslate()
                    } else {
                        vm.runPolish()
                    }
                }) {
                    if vm.isLoading {
                        ProgressView().controlSize(.small)
                            .padding(.horizontal, 10)
                    } else {
                        Text(vm.selectedTab == .translate ? "Translate" : "Polish")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.isLoading || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Output
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.selectedTab == .translate ? "Sinhala Meaning:" : "Polished English:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !vm.outputText.isEmpty {
                        Button(action: {
                            vm.copyOutput()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: vm.copied ? "checkmark" : "doc.on.doc")
                                Text(vm.copied ? "Copied!" : "Copy")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                }

                ScrollView {
                    Text(vm.outputText.isEmpty ? (vm.isLoading ? "Translating with AI..." : "Result will appear here...") : vm.outputText)
                        .font(.system(size: 14))
                        .foregroundColor(vm.outputText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 85)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                if !vm.errorMessage.isEmpty {
                    Text("Error: \(vm.errorMessage)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Bottom bar
            HStack {
                Button("Esc to close") {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Quit App") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 480, height: 380)
        .background(VisualEffectView().cornerRadius(12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .popover
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
