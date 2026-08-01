import SwiftUI
import UIKit

enum AppTab: Hashable {
    case counter
    case records
    case export
    case settings
}

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .counter

    var body: some View {
        TabView(selection: $selectedTab) {
            CounterView()
                .tabItem {
                    Label("Counter", systemImage: "plus.circle.fill")
                }
                .tag(AppTab.counter)

            RecordsView()
                .tabItem {
                    Label("Records", systemImage: "list.bullet.rectangle")
                }
                .tag(AppTab.records)

            ExportView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .tag(AppTab.export)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .onAppear(perform: updateScreenAwakeState)
        .onChange(of: selectedTab) { _ in updateScreenAwakeState() }
        .onChange(of: scenePhase) { _ in updateScreenAwakeState() }
        .onChange(of: store.state.settings.keepScreenAwake) { _ in updateScreenAwakeState() }
    }

    private func updateScreenAwakeState() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            && selectedTab == .counter
            && store.state.settings.keepScreenAwake
    }
}
