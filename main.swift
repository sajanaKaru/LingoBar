import SwiftUI
import AppKit

@main
struct LingoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = MainContentView()

        popover.contentSize = NSSize(width: 440, height: 460)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🇱🇰 LingoBar"
            button.action = #selector(togglePopover)
            button.target = self
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // Option + Shift + L to toggle
            if event.modifierFlags.contains([.option, .shift]) && event.keyCode == 37 { // 37 is 'L'
                self?.togglePopover()
            }
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                // Auto-read clipboard or selected text
                NotificationCenter.default.post(name: NSNotification.Name("PopoverOpened"), object: nil)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
    
    // Tone for polishing
    @Published var polishTone: String = "Natural"

    @Published var apiKey: String = ""
    @Published var storageError: String = ""
    @Published var pendingFallbackConflictKey: String? = nil
    @Published var fallbackWarning: String = ""

    init() {
        do {
            try KeychainHelper.shared.migrateLegacyKeyIfNeeded()
            self.apiKey = (try KeychainHelper.shared.getKey()) ?? ""
            self.pendingFallbackConflictKey = KeychainHelper.shared.pendingFallbackConflictKey
            self.fallbackWarning = KeychainHelper.shared.fallbackRecoveryWarning ?? ""
            self.storageError = ""
        } catch {
            self.storageError = "Keychain error: \(error.localizedDescription)"
            self.apiKey = ""
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleOpen), name: NSNotification.Name("PopoverOpened"), object: nil)
    }

    func refreshApiKey() {
        DispatchQueue.main.async {
            do {
                self.apiKey = (try KeychainHelper.shared.getKey()) ?? ""
                self.pendingFallbackConflictKey = KeychainHelper.shared.pendingFallbackConflictKey
                self.fallbackWarning = KeychainHelper.shared.fallbackRecoveryWarning ?? ""
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

    @objc func handleOpen() {
        // If clipboard has new text, optionally offer or check
        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty, inputText.isEmpty {
            inputText = clip
            if selectedTab == .translate {
                runTranslate()
            }
        }
    }

    func runTranslate() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            if storageError.isEmpty {
                errorMessage = "API Key not configured. Please open Settings (⌘,) to configure."
            }
            return
        }
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
        guard !apiKey.isEmpty else {
            if storageError.isEmpty {
                errorMessage = "API Key not configured. Please open Settings (⌘,) to configure."
            }
            return
        }
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
            completion(.failure(NSError(domain: "LingoBar", code: 401, userInfo: [NSLocalizedDescriptionKey: "Groq API Key not found. Please configure it in Settings (⌘,)."])))
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
    @StateObject var vm = AppViewModel()
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("🇱🇰 LingoBar")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text("Shortcut: ⌥⇧L")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .keyboardShortcut(",", modifiers: [.command])
            }
            .padding(.top, 4)

            // Storage / Keychain Error Banner
            if !vm.storageError.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                    Text(vm.storageError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            // Empty State Banner when API Key is missing
            if vm.apiKey.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("API Key Not Configured")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Configure your Groq API key in Settings to enable AI translation and polishing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: { showSettings = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.fill")
                            Text("Configure API Key")
                        }
                        .font(.caption)
                        .fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
            }

            // Tab Picker
            Picker("", selection: $vm.selectedTab) {
                Text("Translate (සිංහල)").tag(AppTab.translate)
                Text("Polish English").tag(AppTab.polish)
            }
            .pickerStyle(.segmented)

            // Polish Tone picker if on polish tab
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

            // Input Area
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.selectedTab == .translate ? "English Text to Translate:" : "Draft English to Polish:")
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
                    .frame(height: 80)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            // Action Button
            HStack {
                Button(action: {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        vm.inputText = clip
                    }
                }) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: {
                    if vm.apiKey.isEmpty {
                        showSettings = true
                    } else if vm.selectedTab == .translate {
                        vm.runTranslate()
                    } else {
                        vm.runPolish()
                    }
                }) {
                    if vm.isLoading {
                        ProgressView().controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text(vm.apiKey.isEmpty ? "Configure Key" : (vm.selectedTab == .translate ? "Translate to සිංහල" : "Polish English"))
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.isLoading || (!vm.apiKey.isEmpty && vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }

            // Output Area
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.selectedTab == .translate ? "Sinhala Meaning (සරල සිංහල):" : "Polished English:")
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
                .frame(height: 90)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                if !vm.errorMessage.isEmpty {
                    Text("Error: \(vm.errorMessage)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Footer
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
                Spacer()
                Text("⌘ + Return to run")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 2)
        }
        .padding(14)
        .frame(width: 440)
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings, onKeySaved: {
                vm.refreshApiKey()
            })
        }
    }
}
