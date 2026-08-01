import AudioToolbox
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum FeedbackKind {
    case increment
    case decrement
    case success
    case warning
    case selection
}

@MainActor
enum FeedbackController {
    static func play(_ kind: FeedbackKind, hapticsEnabled: Bool, soundEnabled: Bool) {
        if hapticsEnabled {
            switch kind {
            case .increment:
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            case .decrement:
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .selection:
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }

        guard soundEnabled else { return }
        switch kind {
        case .success:
            AudioServicesPlaySystemSound(1057)
        case .warning:
            AudioServicesPlaySystemSound(1053)
        case .increment, .decrement, .selection:
            AudioServicesPlaySystemSound(1104)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DocumentExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    var completion: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = urls.count > 1
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(false)
        }
    }
}

struct DocumentImportPicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .commaSeparatedText, .plainText],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Result<URL, Error>) -> Void

        init(completion: @escaping (Result<URL, Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                completion(.failure(TransferPickerError.missingSelection))
                return
            }
            completion(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

enum TransferPickerError: LocalizedError {
    case missingSelection

    var errorDescription: String? {
        "The document picker did not return a file."
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String = "Unable to Complete Action", error: Error) {
        self.title = title
        self.message = error.localizedDescription
    }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

extension View {
    func presentedErrorAlert(_ error: Binding<PresentedError?>) -> some View {
        alert(item: error) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
