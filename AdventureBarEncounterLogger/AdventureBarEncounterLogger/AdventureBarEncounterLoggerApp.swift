import SwiftUI

@main
@MainActor
struct AdventureBarEncounterLoggerApp: App {
    private let startupResult: Result<AppStore, Error>

    init() {
        startupResult = Result { try AppStore() }
    }

    var body: some Scene {
        WindowGroup {
            switch startupResult {
            case .success(let store):
                AppContentView(store: store)
            case .failure(let error):
                StartupErrorView(error: error)
            }
        }
    }
}

private struct AppContentView: View {
    @StateObject private var store: AppStore

    init(store: AppStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        RootTabView()
            .environmentObject(store)
            .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.state.settings.appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private struct StartupErrorView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text("Data Store Could Not Be Opened")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("The app left all existing files unchanged to protect your records.")
                .multilineTextAlignment(.center)
            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Close and reopen the app. If the problem remains, do not remove the guest or its data. Preserve the LiveContainer guest data container if available, and copy any existing Documents exports before troubleshooting Application Support.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
    }
}
