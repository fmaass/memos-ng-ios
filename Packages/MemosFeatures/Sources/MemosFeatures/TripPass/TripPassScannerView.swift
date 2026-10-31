import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import VisionKit

/// The one claim a scanner makes.
///
/// A camera held on a QR code reports it again and again, and through two callbacks (an item
/// added, an item tapped). The first PASS LINK wins and nothing after it does: claimed here,
/// synchronously, inside the delegate callback and before any hop, so two reports can never become
/// two redeems. A code that is not a pass link (a menu, a Wi-Fi code) is not claimed, so it cannot
/// use up the scanner's one answer.
final class TripPassScanClaim {
    private(set) var claimed: URL?

    func claim(_ payload: String?) -> URL? {
        guard claimed == nil, let payload, let url = URL(string: payload),
            GuestDoor.secret(fromPassLink: url) != nil
        else { return nil }
        claimed = url
        return url
    }
}

/// VisionKit's live scanner, QR only, handing back the first pass link it sees.
///
/// Shown only when `isAvailable`: a phone without the scanner, or with the camera refused, gets
/// the paste field alone. A fresh view identity is a fresh claim — the join screen's "Scan again".
struct TripPassScannerView: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onPassLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPassLink: onPassLink) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPassLink = onPassLink
        guard !scanner.isScanning, context.coordinator.claim.claimed == nil else { return }
        do {
            try scanner.startScanning()
        } catch {
            // `isAvailable` was asked before this view was shown; a camera taken away in between
            // leaves the paste field, which is always there.
            let detail = String(describing: error)
            MemosLog.session.error("trip pass scanner did not start: \(detail)")
        }
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController, coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let claim = TripPassScanClaim()
        var onPassLink: (URL) -> Void

        init(onPassLink: @escaping (URL) -> Void) {
            self.onPassLink = onPassLink
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems { offer(item, from: dataScanner) }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem
        ) {
            offer(item, from: dataScanner)
        }

        private func offer(_ item: RecognizedItem, from scanner: DataScannerViewController) {
            guard case .barcode(let code) = item, let url = claim.claim(code.payloadStringValue)
            else { return }
            scanner.stopScanning()
            onPassLink(url)
        }
    }
}
