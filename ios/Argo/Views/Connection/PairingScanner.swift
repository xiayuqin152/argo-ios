// Adapted from nwverse/persona apple/Persona/Views/Settings/SettingsView.swift
// QRScanner @ 89927b54baab6b8207315f6c2a4d2e5831598d45 (MIT).
import SwiftUI
import VisionKit

/// Persona's native QR scanner; each presentation delivers at most one code.
struct PairingScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                  qualityLevel: .balanced, isHighlightingEnabled: true)
        let coordinator = context.coordinator
        controller.delegate = coordinator
        // Defer callbacks until the SwiftUI update that creates the controller ends.
        coordinator.startTask = Task { @MainActor [weak controller, weak coordinator] in
            guard let controller, let coordinator, !Task.isCancelled, !coordinator.finished else { return }
            do { try controller.startScanning() }
            catch { coordinator.unavailable(controller) }
        }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onUnavailable = onUnavailable
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stop(controller)
        controller.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onUnavailable: onUnavailable) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var onUnavailable: () -> Void
        var startTask: Task<Void, Never>?
        private(set) var finished = false

        init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func stop(_ scanner: DataScannerViewController) {
            finished = true
            startTask?.cancel()
            startTask = nil
            scanner.stopScanning()
        }

        func unavailable(_ scanner: DataScannerViewController) {
            guard !finished else { return }
            stop(scanner)
            onUnavailable()
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in items {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    stop(scanner)
                    onCode(payload)
                    return
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            unavailable(scanner)
        }
    }
}
