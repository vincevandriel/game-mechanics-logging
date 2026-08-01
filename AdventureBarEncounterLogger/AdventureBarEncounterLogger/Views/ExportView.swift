import SwiftUI

private enum ExportScope: String, CaseIterable, Identifiable {
    case active = "Active Session"
    case selected = "Selected Session"
    case all = "All Sessions"

    var id: String { rawValue }
}

private enum ExportPresentationMode {
    case files
    case share
}

private struct ExportPresentation: Identifiable {
    let id = UUID()
    let url: URL
    let mode: ExportPresentationMode
}

struct ExportView: View {
    @EnvironmentObject private var store: AppStore

    @State private var scope: ExportScope = .active
    @State private var selectedSessionID: UUID?
    @State private var format: ExportFormat = .csv
    @State private var content: ExportContent = .observationsAndSessionMetadata
    @State private var presentation: ExportPresentation?
    @State private var showingImportPicker = false
    @State private var importPreview: ImportPreview?
    @State private var isSendingToPC = false
    @State private var statusMessage: String?
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            Form {
                Section("Export Scope") {
                    Picker("Sessions", selection: $scope) {
                        ForEach(ExportScope.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }

                    if scope == .selected {
                        Picker("Selected session", selection: selectedSessionBinding) {
                            ForEach(store.state.sessions) { session in
                                Text(session.name).tag(session.id)
                            }
                        }
                    }
                }

                Section("File Contents") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { value in
                            Text(value.displayName)
                                .tag(value)
                                .disabled(content == .completeBackup && value == .csv)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Include", selection: $content) {
                        ForEach(ExportContent.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }

                    if content == .completeBackup {
                        Text("Complete backups use JSON so settings, unfinished counter state, audit history, and recovery history remain intact.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Manual Export") {
                    Button {
                        createExport(for: .files)
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                    }

                    Button {
                        createExport(for: .share)
                    } label: {
                        Label("Open Share Sheet", systemImage: "square.and.arrow.up")
                    }

                    Text("The share sheet can save to a Google Drive-backed Files location when Google Drive is installed and enabled in Files.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("PC Transfer") {
                    HStack {
                        Text("Receiver")
                        Spacer()
                        Text(receiverDescription)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    Button(action: sendToPC) {
                        HStack {
                            Label("Send to PC Receiver", systemImage: "desktopcomputer.and.arrow.down")
                            Spacer()
                            if isSendingToPC { ProgressView() }
                        }
                    }
                    .disabled(!receiverIsConfigured || isSendingToPC)

                    Text("Transfers occur only when you tap Send. A failure never deletes or changes local data.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Import and Restore") {
                    Button {
                        showingImportPicker = true
                    } label: {
                        Label("Choose CSV or JSON File", systemImage: "square.and.arrow.down")
                    }

                    Text("Files are validated before you choose Merge or Replace. Duplicate observation UUIDs are skipped during merge.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Export")
            .onAppear {
                format = store.state.settings.lastExportFormat
                ensureSelectedSession()
            }
            .onChange(of: content) { value in
                if value == .completeBackup { format = .json }
            }
            .onChange(of: store.state.sessions.map(\.id)) { _ in ensureSelectedSession() }
            .sheet(item: $presentation) { item in
                switch item.mode {
                case .files:
                    DocumentExportPicker(urls: [item.url])
                case .share:
                    ShareSheet(items: [item.url])
                }
            }
            .sheet(isPresented: $showingImportPicker) {
                DocumentImportPicker { result in
                    showingImportPicker = false
                    switch result {
                    case .success(let url):
                        previewImport(url)
                    case .failure(let error):
                        presentedError = PresentedError(title: "Unable to Read Import", error: error)
                    }
                }
            }
            .sheet(item: $importPreview) { preview in
                ImportPreviewView(preview: preview) { message in
                    statusMessage = message
                }
                .environmentObject(store)
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var selectedSessionBinding: Binding<UUID> {
        Binding(
            get: { selectedSessionID ?? store.state.activeSessionID },
            set: { selectedSessionID = $0 }
        )
    }

    private var receiverIsConfigured: Bool {
        store.state.settings.pcReceiverHost.nilIfBlank != nil
            && (1...65_535).contains(store.state.settings.pcReceiverPort)
            && ReceiverRequestSigner.isValidSecret(store.state.settings.pcReceiverUploadSecret)
    }

    private var receiverDescription: String {
        guard receiverIsConfigured else { return "Not configured" }
        let settings = store.state.settings
        let authentication = settings.pcReceiverUploadSecret.isEmpty ? "unsigned" : "signed"
        return "\(settings.pcReceiverScheme.rawValue)://\(settings.pcReceiverHost):\(settings.pcReceiverPort) (\(authentication))"
    }

    private var exportSelection: ExportSelection {
        switch scope {
        case .active:
            return .activeSession
        case .selected:
            return .session(selectedSessionID ?? store.state.activeSessionID)
        case .all:
            return .allSessions
        }
    }

    private func ensureSelectedSession() {
        guard let selectedSessionID,
              store.state.sessions.contains(where: { $0.id == selectedSessionID }) else {
            self.selectedSessionID = store.state.activeSessionID
            return
        }
    }

    private func exportedFile() throws -> ExportedFile {
        try store.exportService.export(
            state: store.state,
            selection: exportSelection,
            format: format,
            content: content
        )
    }

    private func createExport(for mode: ExportPresentationMode) {
        do {
            let exported = try exportedFile()
            let url = try store.exportService.write(
                exported,
                to: store.persistenceService.documentsDirectoryURL
            )
            saveLastUsedFormat()
            statusMessage = "Created \(url.lastPathComponent) with \(exported.observationCount) observations"
            presentation = ExportPresentation(url: url, mode: mode)
        } catch {
            presentedError = PresentedError(title: "Unable to Export", error: error)
        }
    }

    private func saveLastUsedFormat() {
        guard store.state.settings.lastExportFormat != format else { return }
        var settings = store.state.settings
        settings.lastExportFormat = format
        do {
            try store.updateSettings(settings)
        } catch {
            presentedError = PresentedError(title: "Export Created, but Setting Was Not Saved", error: error)
        }
    }

    private func sendToPC() {
        guard receiverIsConfigured else { return }
        isSendingToPC = true
        statusMessage = nil

        Task {
            do {
                let receipt = try await store.transferExport(
                    selection: exportSelection,
                    format: format,
                    content: content
                )
                saveLastUsedFormat()
                statusMessage = receipt.message
                isSendingToPC = false
            } catch {
                presentedError = PresentedError(title: "PC Transfer Failed", error: error)
                isSendingToPC = false
            }
        }
    }

    private func previewImport(_ url: URL) {
        do {
            let preview = try store.importService.preview(fileURL: url, existingState: store.state)
            importPreview = preview
        } catch {
            presentedError = PresentedError(title: "Unable to Preview Import", error: error)
        }
    }
}

private struct ImportPreviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let preview: ImportPreview
    let completion: (String) -> Void

    @State private var showingReplaceConfirmation = false
    @State private var errorReportURL: URL?
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            List {
                Section("Validated File") {
                    detailRow("File", preview.sourceFilename)
                    detailRow("Format", preview.detectedFormat.rawValue)
                    detailRow("Sessions", "\(preview.sessionCount)")
                    detailRow("Valid observations", "\(preview.observationCount)")
                    detailRow("Rejected rows", "\(preview.rejectedRowCount)")
                    detailRow("Duplicate UUIDs", "\(preview.duplicateObservationIDs.count)")
                }

                if !preview.issues.isEmpty {
                    Section("Warnings and Errors") {
                        ForEach(preview.issues) { issue in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(issue.severity == .error ? .red : .orange)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    if let row = issue.rowNumber {
                                        Text("Row \(row)")
                                            .font(.caption.weight(.semibold))
                                    }
                                    Text(issue.message)
                                        .font(.subheadline)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Button("Share Import Error Report", action: prepareErrorReport)
                    }
                }

                Section {
                    Button("Merge with Existing Data") {
                        apply(.merge)
                    }
                    .disabled(!preview.canImport)

                    Button("Replace Existing Data", role: .destructive) {
                        showingReplaceConfirmation = true
                    }
                    .disabled(!preview.canImport || preview.hasErrors)
                } footer: {
                    Text("Replace first creates a pre-import backup. Replacement is disabled while rejected rows remain.")
                }
            }
            .navigationTitle("Import Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Replace All Existing Data?",
                isPresented: $showingReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button("Replace After Creating Backup", role: .destructive) {
                    apply(.replace)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Current sessions, observations, settings, and unfinished counter state will be replaced by the validated import.")
            }
            .sheet(item: reportBinding) { url in
                ShareSheet(items: [url])
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func apply(_ mode: ImportMode) {
        do {
            let result = try store.applyImport(preview, mode: mode)
            let message = "Imported \(result.importedObservationCount) observations in \(result.importedSessionCount) sessions; skipped \(result.duplicateObservationCount) duplicates"
            completion(message)
            dismiss()
        } catch {
            presentedError = PresentedError(title: "Import Failed", error: error)
        }
    }

    private var reportBinding: Binding<IdentifiedURL?> {
        Binding(
            get: { errorReportURL.map(IdentifiedURL.init) },
            set: { errorReportURL = $0?.url }
        )
    }

    private func prepareErrorReport() {
        do {
            let safeBase = preview.sourceFilename.replacingOccurrences(of: ".", with: "_")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AdventureBar_ImportErrors_\(safeBase).txt")
            try preview.errorReportData.write(to: url, options: .atomic)
            errorReportURL = url
        } catch {
            presentedError = PresentedError(title: "Unable to Create Error Report", error: error)
        }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }

    init(_ url: URL) {
        self.url = url
    }
}
