import SwiftUI
import AppKit

public enum KeyConnectionStatus: Equatable {
    case notConfigured
    case unverified
    case testing
    case connected
    case invalid(String)
}

public struct SettingsView: View {
    @Binding public var isPresented: Bool
    public var onKeySaved: (() -> Void)?

    @State private var selectedProvider: String = "Groq"
    @State private var enteredKey: String = ""
    @State private var showKey: Bool = false
    @State private var keyStatus: KeyConnectionStatus = .notConfigured
    @State private var isTesting: Bool = false
    @State private var initialKey: String = ""
    @State private var errorMessage: String = ""
    @State private var currentTestTask: URLSessionDataTask?
    @State private var lastTestedKey: String = ""

    public init(isPresented: Binding<Bool>, onKeySaved: (() -> Void)? = nil) {
        self._isPresented = isPresented
        self.onKeySaved = onKeySaved
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                Text("Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: {
                    cancelInFlightTest()
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Settings")
            }
            .padding(.bottom, 2)

            Divider()

            // AI Provider Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Provider:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedProvider) {
                    Text("Groq (Llama 3 / Qwen) — Recommended").tag("Groq")
                    Text("OpenAI (Coming soon)").tag("OpenAI")
                    Text("Anthropic (Coming soon)").tag("Anthropic")
                    Text("Gemini (Coming soon)").tag("Gemini")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // API Key Input Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Groq API Key:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        if let url = URL(string: "https://console.groq.com/keys") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Text("Get Free Key")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    if showKey {
                        TextField("gsk_...", text: $enteredKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        SecureField("gsk_...", text: $enteredKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    // Show / Hide Key Toggle
                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(showKey ? "Hide API Key" : "Show API Key")

                    // Paste Button
                    Button(action: pasteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Paste from Clipboard")
                }
            }

            // Status Badge and Test Connection
            HStack(spacing: 12) {
                // Status Badge
                HStack(spacing: 5) {
                    switch keyStatus {
                    case .notConfigured:
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("Not Configured")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    case .unverified:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.yellow)
                        Text("Saved (Unverified)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.yellow)
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .connected:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connected")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    case .invalid(let reason):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(reason)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Spacer()

                // Test Connection Button
                Button(action: testConnection) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                            .frame(width: 80)
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting || enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Error display if Keychain operation failed
            if !errorMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Divider()

            // Footer Actions
            HStack {
                if !enteredKey.isEmpty {
                    Button(action: clearKey) {
                        Text("Clear Key")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }

                Spacer()

                Button("Cancel") {
                    cancelInFlightTest()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Save") {
                    saveKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isTesting)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear(perform: loadCurrentKey)
        .onChange(of: enteredKey) { _, newKey in
            handleInputChanged(newKey: newKey)
        }
    }

    private func cancelInFlightTest() {
        currentTestTask?.cancel()
        currentTestTask = nil
        isTesting = false
    }

    private func handleInputChanged(newKey: String) {
        // Cancel in-flight test when user changes input to prevent race conditions
        if isTesting {
            cancelInFlightTest()
        }

        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keyStatus = .notConfigured
        } else if trimmed == lastTestedKey && keyStatus == .connected {
            // Key matches the one that was tested and connected
        } else if trimmed == initialKey {
            keyStatus = .unverified
        } else {
            keyStatus = .notConfigured
        }
        errorMessage = ""
    }

    private func loadCurrentKey() {
        errorMessage = ""
        do {
            if let key = try KeychainHelper.shared.getKey(), !key.isEmpty {
                enteredKey = key
                initialKey = key
                keyStatus = .unverified
            } else {
                keyStatus = .notConfigured
            }
        } catch {
            errorMessage = error.localizedDescription
            keyStatus = .notConfigured
        }
    }

    private func pasteFromClipboard() {
        if let clip = NSPasteboard.general.string(forType: .string) {
            let trimmed = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                enteredKey = trimmed
            }
        }
    }

    private func clearKey() {
        cancelInFlightTest()
        errorMessage = ""
        do {
            try KeychainHelper.shared.deleteKey()
            enteredKey = ""
            initialKey = ""
            lastTestedKey = ""
            keyStatus = .notConfigured
            onKeySaved?()
        } catch {
            errorMessage = "Failed to delete key: \(error.localizedDescription)"
        }
    }

    private func testConnection() {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyStatus = .notConfigured
            return
        }

        cancelInFlightTest()
        isTesting = true
        keyStatus = .testing
        errorMessage = ""
        let targetKey = trimmed

        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else {
            isTesting = false
            keyStatus = .invalid("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(targetKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5.0

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                self.isTesting = false
                self.currentTestTask = nil

                // Race condition check: Verify current text still matches the tested key
                let currentTrimmed = self.enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentTrimmed == targetKey else {
                    return
                }

                if let error = error {
                    let nsErr = error as NSError
                    if nsErr.code == NSURLErrorCancelled {
                        return
                    } else if nsErr.code == NSURLErrorTimedOut {
                        self.keyStatus = .invalid("Connection timed out (5s)")
                    } else {
                        self.keyStatus = .invalid("Network error")
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.keyStatus = .invalid("No response")
                    return
                }

                if httpResponse.statusCode == 200 {
                    self.keyStatus = .connected
                    self.lastTestedKey = targetKey
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self.keyStatus = .invalid("Invalid Key (401)")
                } else {
                    self.keyStatus = .invalid("Error (\(httpResponse.statusCode))")
                }
            }
        }
        currentTestTask = task
        task.resume()
    }

    private func saveKey() {
        cancelInFlightTest()
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = ""

        do {
            if trimmed.isEmpty {
                try KeychainHelper.shared.deleteKey()
                initialKey = ""
                keyStatus = .notConfigured
            } else {
                try KeychainHelper.shared.saveKey(trimmed)
                initialKey = trimmed
                if trimmed != lastTestedKey || keyStatus != .connected {
                    keyStatus = .unverified
                }
            }
            onKeySaved?()
            isPresented = false
        } catch {
            errorMessage = "Failed to save key: \(error.localizedDescription)"
            // Do NOT dismiss settings on error
        }
    }
}
