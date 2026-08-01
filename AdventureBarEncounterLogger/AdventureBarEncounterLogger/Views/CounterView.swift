import SwiftUI

struct CounterView: View {
    @EnvironmentObject private var store: AppStore

    @State private var requestedMode: MovementMode?
    @State private var showingModeChangeOptions = false
    @State private var showingZeroConfirmation = false
    @State private var showingUndoOptions = false
    @State private var confirmationText: String?
    @State private var confirmationToken = UUID()
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                VStack(spacing: geometry.size.height < 600 ? 10 : 16) {
                    modeSelector

                    if let session = store.activeSession {
                        Text(session.name)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Active session: \(session.name)")
                    }

                    Spacer(minLength: 0)

                    Text("\(store.currentCount)")
                        .font(.system(size: countFontSize(for: geometry.size), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.35)
                        .lineLimit(1)
                        .accessibilityLabel("Current step count")
                        .accessibilityValue("\(store.currentCount)")

                    if store.currentIntervalMode == .mixedUncertain {
                        Label("Mixed/Uncertain interval", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.orange)
                            .accessibilityHint("The next submitted observation will be marked Mixed or Uncertain")
                    }

                    if let confirmationText {
                        Text(confirmationText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isStaticText)
                    }

                    Spacer(minLength: 0)

                    incrementControls(height: geometry.size.height)
                    submissionControls
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .confirmationDialog(
            "Change Movement Mode?",
            isPresented: $showingModeChangeOptions,
            titleVisibility: .visible
        ) {
            Button("Reset Current Count and Switch", role: .destructive) {
                resolveModeChange(.resetAndSwitch)
            }
            Button("Switch and Preserve Count") {
                resolveModeChange(.preserveAndMarkMixed)
            }
            Button("Cancel", role: .cancel) {
                requestedMode = nil
            }
        } message: {
            Text("The current interval already contains \(store.currentCount) steps. Preserving it will mark the next observation Mixed/Uncertain.")
        }
        .confirmationDialog(
            "Record Zero Steps?",
            isPresented: $showingZeroConfirmation,
            titleVisibility: .visible
        ) {
            Button("Record Zero", role: .destructive) {
                submit(allowZero: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zero-value observations are unusual. Confirm that zero is the exact raw value you intend to save.")
        }
        .confirmationDialog(
            "Undo Last Submission?",
            isPresented: $showingUndoOptions,
            titleVisibility: .visible
        ) {
            Button("Replace Current Count", role: .destructive) {
                undo(strategy: .replace)
            }
            Button("Add Current Count") {
                undo(strategy: .addCurrentCount)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restoring the last submitted observation can replace the unfinished count of \(store.currentCount), or add those steps to it.")
        }
        .presentedErrorAlert($presentedError)
    }

    private var modeSelector: some View {
        Picker("Movement mode", selection: Binding(
            get: { store.selectedBaseMode },
            set: { requestModeChange(to: $0) }
        )) {
            Text("Walking").tag(MovementMode.walking)
            Text("Running").tag(MovementMode.running)
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Select the movement used for the current encounter interval")
    }

    private func incrementControls(height: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button(action: decrement) {
                VStack(spacing: 2) {
                    Image(systemName: "minus")
                        .font(.title2.weight(.bold))
                    Text("Minus")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(CounterButtonStyle(background: Color.secondary.opacity(0.16), foreground: .primary))
            .frame(width: 104, height: max(70, min(96, height * 0.15)))
            .disabled(store.currentCount == 0)
            .accessibilityLabel("Minus one step")
            .accessibilityHint("Decreases the current count by one")

            Button(action: increment) {
                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 36, weight: .bold))
                    Text("Plus One")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(CounterButtonStyle(background: .accentColor, foreground: .white))
            .frame(height: max(88, min(126, height * 0.19)))
            .accessibilityLabel("Plus one step")
            .accessibilityHint("Adds one successful tile movement")
        }
    }

    private var submissionControls: some View {
        HStack(spacing: 12) {
            Button(action: undoButtonTapped) {
                Label(
                    store.canRedoUndo ? "Reverse Undo" : "Undo",
                    systemImage: store.canRedoUndo ? "arrow.uturn.forward" : "arrow.uturn.backward"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(!store.canUndo && !store.canRedoUndo)
            .accessibilityHint(
                store.canRedoUndo
                    ? "Reverses the last Undo and restores the observation"
                    : "Removes the last observation in this session and restores its count"
            )

            Button(action: requestSubmit) {
                Label("Submit", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Records this encounter interval and immediately resets the count")
        }
    }

    private func countFontSize(for size: CGSize) -> CGFloat {
        min(min(size.width * 0.44, size.height * 0.26), 190)
    }

    private func increment() {
        do {
            try store.increment()
            play(.increment)
        } catch {
            presentedError = PresentedError(error: error)
        }
    }

    private func decrement() {
        do {
            try store.decrement()
            play(.decrement)
        } catch {
            presentedError = PresentedError(error: error)
        }
    }

    private func requestModeChange(to mode: MovementMode) {
        guard mode != store.selectedBaseMode else { return }
        if store.currentCount > 0 {
            requestedMode = mode
            showingModeChangeOptions = true
        } else {
            requestedMode = mode
            resolveModeChange(nil)
        }
    }

    private func resolveModeChange(_ resolution: ModeChangeResolution?) {
        guard let requestedMode else { return }
        do {
            try store.changeMode(to: requestedMode, resolution: resolution)
            self.requestedMode = nil
            play(.selection)
        } catch {
            presentedError = PresentedError(title: "Unable to Change Mode", error: error)
        }
    }

    private func requestSubmit() {
        if store.currentCount == 0 && store.state.settings.confirmZeroSubmission {
            showingZeroConfirmation = true
        } else {
            submit(allowZero: store.currentCount == 0)
        }
    }

    private func submit(allowZero: Bool) {
        do {
            let observation = try store.submitCurrentCount(allowZero: allowZero)
            showConfirmation("Recorded: \(observation.stepCount) \(observation.movementMode.displayName)")
            play(.success)
        } catch AppStoreError.zeroSubmissionRequiresConfirmation {
            showingZeroConfirmation = true
            play(.warning)
        } catch {
            presentedError = PresentedError(title: "Unable to Submit", error: error)
            play(.warning)
        }
    }

    private func requestUndo() {
        guard store.canUndo else { return }
        if store.currentCount > 0 && store.state.settings.confirmUndoReplaceNonzero {
            showingUndoOptions = true
        } else {
            undo(strategy: .replace)
        }
    }

    private func undoButtonTapped() {
        if store.canRedoUndo {
            do {
                try store.redoUndo()
                showConfirmation("Undo reversed")
                play(.selection)
            } catch {
                presentedError = PresentedError(title: "Unable to Reverse Undo", error: error)
            }
        } else {
            requestUndo()
        }
    }

    private func undo(strategy: UndoStrategy) {
        do {
            _ = try store.undoLastSubmission(strategy: strategy)
            showConfirmation("Restored: \(store.currentCount) \(store.currentIntervalMode.displayName)")
            play(.warning)
        } catch AppStoreError.undoRequiresCurrentCountConfirmation {
            showingUndoOptions = true
            play(.warning)
        } catch {
            presentedError = PresentedError(title: "Unable to Undo", error: error)
        }
    }

    private func showConfirmation(_ text: String) {
        let token = UUID()
        confirmationToken = token
        confirmationText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard confirmationToken == token else { return }
            confirmationText = nil
        }
    }

    private func play(_ kind: FeedbackKind) {
        let settings = store.state.settings
        FeedbackController.play(
            kind,
            hapticsEnabled: settings.hapticsEnabled,
            soundEnabled: settings.soundFeedbackEnabled
        )
    }
}

private struct CounterButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(foreground)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
