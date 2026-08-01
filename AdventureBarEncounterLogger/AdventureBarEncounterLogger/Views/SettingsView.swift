import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var receiverHost = ""
    @State private var receiverPort = "8765"
    @State private var receiverScheme: ReceiverScheme = .http
    @State private var receiverUploadSecret = ""
    @State private var showsReceiverSecret = false
    @State private var confirmsSecretReplacement = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: ConnectionStatus?
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            Form {
                Section("Counter Feedback") {
                    Toggle("Haptic feedback", isOn: settingBinding(\.hapticsEnabled))
                    Toggle("Sound feedback", isOn: settingBinding(\.soundFeedbackEnabled))
                    Toggle("Keep screen awake on Counter", isOn: settingBinding(\.keepScreenAwake))
                }

                Section("Recording Defaults") {
                    Stepper(
                        "Measurement uncertainty: ±\(store.state.settings.defaultMeasurementUncertainty)",
                        value: settingBinding(\.defaultMeasurementUncertainty),
                        in: 0...999
                    )
                    Toggle("Confirm before submitting zero", isOn: settingBinding(\.confirmZeroSubmission))
                    Toggle("Confirm before Undo replaces a count", isOn: settingBinding(\.confirmUndoReplaceNonzero))
                }

                Section("Exports") {
                    Toggle(
                        "Create Export Snapshot After Every Submission",
                        isOn: settingBinding(\.createExportSnapshotsAfterEverySubmission)
                    )
                    Picker("Last-used format", selection: settingBinding(\.lastExportFormat)) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                }

                Section("PC Receiver") {
                    Picker("Protocol", selection: $receiverScheme) {
                        ForEach(ReceiverScheme.allCases) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("PC IP address or hostname", text: $receiverHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Port", text: $receiverPort)
                        .keyboardType(.numberPad)

                    if showsReceiverSecret {
                        TextField("64-character upload secret", text: $receiverUploadSecret)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("64-character upload secret (optional)", text: $receiverUploadSecret)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    Toggle("Show Upload Secret", isOn: $showsReceiverSecret)

                    Button(receiverUploadSecret.isEmpty ? "Generate Upload Secret" : "Generate Replacement Secret") {
                        if receiverUploadSecret.isEmpty {
                            receiverUploadSecret = ReceiverRequestSigner.generateSecret()
                            showsReceiverSecret = true
                        } else {
                            confirmsSecretReplacement = true
                        }
                    }

                    Button("Copy Upload Secret") {
                        UIPasteboard.general.string = normalizedReceiverSecret
                        connectionStatus = ConnectionStatus(
                            message: "Upload secret copied",
                            systemImage: "doc.on.doc.fill",
                            isSuccess: true
                        )
                    }
                    .disabled(!receiverSecretIsConfiguredAndValid)

                    if !receiverSecretIsValid {
                        Label("Use exactly 64 hexadecimal characters, or leave the secret empty for unsigned LAN uploads.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.red)
                    } else if receiverUploadSecret.isEmpty {
                        Text("No secret: uploads use the original unsigned local-network protocol.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Signed uploads reject files that do not have this same secret. Copy it into the PC receiver configuration. The reachability test does not validate the secret.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    if receiverScheme == .http {
                        Text("HTTP uploads are authenticated when a secret is set, but their CSV/JSON contents are readable in transit. Prefer HTTPS when confidentiality matters.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Button("Save Receiver Settings", action: saveReceiverSettings)
                        .disabled(!receiverValuesAreValid)

                    Button(action: testConnection) {
                        HStack {
                            Text("Test PC Connection")
                            Spacer()
                            if isTestingConnection {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!receiverValuesAreValid || isTestingConnection)

                    if let connectionStatus {
                        Label(connectionStatus.message, systemImage: connectionStatus.systemImage)
                            .font(.footnote)
                            .foregroundColor(connectionStatus.isSuccess ? .green : .red)
                            .accessibilityLabel(connectionStatus.accessibilityLabel)
                    }

                    Toggle(
                        "Automatically Send Current Data to PC",
                        isOn: settingBinding(\.automaticallySendSnapshotToPC)
                    )
                    .disabled(!automaticSyncPrerequisitesAreStored && !store.state.settings.automaticallySendSnapshotToPC)
                    Text("This is off by default and requires a saved signed receiver. It sends after submissions and record/session data changes. Every change is saved locally first, and a failed transfer never deletes local data.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if let status = store.lastPCTransferStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                status.succeeded ? "Last PC transfer succeeded" : "Last PC transfer failed",
                                systemImage: status.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
                            )
                            .foregroundColor(status.succeeded ? .green : .red)
                            Text(status.message)
                            HStack(spacing: 4) {
                                Text(status.automatic ? "Automatic" : "Manual")
                                Text("•")
                                Text(status.timestamp, style: .time)
                            }
                            .foregroundColor(.secondary)
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                    }

                    if let error = store.lastErrorMessage,
                       store.lastPCTransferStatus?.message != error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section("Active Session") {
                    Picker("Session", selection: activeSessionBinding) {
                        ForEach(store.state.sessions.filter { !$0.isArchived }) { session in
                            Text(session.name).tag(session.id)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Color scheme", selection: settingBinding(\.appearance)) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("All records stay on this iPhone. Copies leave only when you manually export/transfer or enable automatic PC snapshots. Logging never depends on a network connection.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadReceiverSettings)
            .onChange(of: receiverUploadSecret) { value in
                let normalized = AppSettings.normalizedReceiverUploadSecret(value)
                if value != normalized { receiverUploadSecret = normalized }
            }
            .confirmationDialog(
                "Replace Upload Secret?",
                isPresented: $confirmsSecretReplacement,
                titleVisibility: .visible
            ) {
                Button("Generate Replacement", role: .destructive) {
                    receiverUploadSecret = ReceiverRequestSigner.generateSecret()
                    showsReceiverSecret = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The PC receiver must be updated with the replacement before signed uploads will work again.")
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var activeSessionBinding: Binding<UUID> {
        Binding(
            get: { store.state.activeSessionID },
            set: { id in
                do {
                    try store.setActiveSession(id: id)
                } catch {
                    presentedError = PresentedError(title: "Unable to Select Session", error: error)
                }
            }
        )
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings[keyPath: keyPath] },
            set: { value in
                var settings = store.state.settings
                settings[keyPath: keyPath] = value
                do {
                    try store.updateSettings(settings)
                } catch {
                    presentedError = PresentedError(title: "Unable to Save Setting", error: error)
                }
            }
        )
    }

    private var receiverValuesAreValid: Bool {
        receiverHost.nilIfBlank != nil
            && Int(receiverPort).map { (1...65_535).contains($0) } == true
            && receiverSecretIsValid
    }

    private var normalizedReceiverSecret: String {
        AppSettings.normalizedReceiverUploadSecret(receiverUploadSecret)
    }

    private var receiverSecretIsValid: Bool {
        ReceiverRequestSigner.isValidSecret(normalizedReceiverSecret)
    }

    private var receiverSecretIsConfiguredAndValid: Bool {
        !normalizedReceiverSecret.isEmpty && ReceiverRequestSigner.isValidSecret(normalizedReceiverSecret, allowingEmpty: false)
    }

    private var automaticSyncPrerequisitesAreStored: Bool {
        let settings = store.state.settings
        return settings.pcReceiverHost.nilIfBlank != nil
            && (1...65_535).contains(settings.pcReceiverPort)
            && ReceiverRequestSigner.isValidSecret(settings.pcReceiverUploadSecret, allowingEmpty: false)
    }

    private func loadReceiverSettings() {
        let settings = store.state.settings
        let storedHost = settings.pcReceiverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if storedHost.lowercased().hasPrefix("https://") {
            receiverScheme = .https
            receiverHost = String(storedHost.dropFirst(8))
        } else if storedHost.lowercased().hasPrefix("http://") {
            receiverScheme = .http
            receiverHost = String(storedHost.dropFirst(7))
        } else {
            receiverScheme = settings.pcReceiverScheme
            receiverHost = storedHost
        }
        receiverPort = String(store.state.settings.pcReceiverPort)
        receiverUploadSecret = settings.pcReceiverUploadSecret
    }

    private func saveReceiverSettings() {
        guard let port = Int(receiverPort), receiverValuesAreValid else { return }
        let normalizedHost = receiverHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive])
        var settings = store.state.settings
        settings.pcReceiverHost = normalizedHost
        settings.pcReceiverPort = port
        settings.pcReceiverScheme = receiverScheme
        settings.pcReceiverUploadSecret = normalizedReceiverSecret
        let disablesAutomaticTransfer = settings.automaticallySendSnapshotToPC
            && normalizedReceiverSecret.isEmpty
        if disablesAutomaticTransfer {
            // Automatic transfer is intentionally signed-only. Saving an
            // unsigned LAN configuration must never leave an enabled-looking
            // toggle whose scheduler cannot run.
            settings.automaticallySendSnapshotToPC = false
        }
        do {
            try store.updateSettings(settings)
            connectionStatus = ConnectionStatus(
                message: disablesAutomaticTransfer
                    ? "Receiver settings saved; automatic transfer was disabled because no upload secret is configured."
                    : "Receiver settings saved",
                systemImage: "checkmark.circle.fill",
                isSuccess: true
            )
        } catch {
            presentedError = PresentedError(title: "Unable to Save Receiver Address", error: error)
        }
    }

    private func testConnection() {
        guard let port = Int(receiverPort), receiverValuesAreValid else { return }
        saveReceiverSettings()
        connectionStatus = nil
        isTestingConnection = true
        let configuration = ReceiverConfiguration(
            scheme: receiverScheme,
            host: receiverHost.replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive]),
            port: port,
            uploadSecret: normalizedReceiverSecret
        )

        Task {
            do {
                let message = try await LocalNetworkTransferService().testConnection(configuration: configuration)
                await MainActor.run {
                    connectionStatus = ConnectionStatus(
                        message: message,
                        systemImage: "checkmark.circle.fill",
                        isSuccess: true
                    )
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    connectionStatus = ConnectionStatus(
                        message: error.localizedDescription,
                        systemImage: "xmark.octagon.fill",
                        isSuccess: false
                    )
                    isTestingConnection = false
                }
            }
        }
    }
}

private struct ConnectionStatus {
    let message: String
    let systemImage: String
    let isSuccess: Bool

    var accessibilityLabel: String {
        (isSuccess ? "Connection succeeded: " : "Connection failed: ") + message
    }
}
