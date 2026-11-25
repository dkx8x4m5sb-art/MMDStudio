import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A reliable UIKit document picker.
///
/// SwiftUI's `.fileImporter` can appear to do nothing for some iCloud/Files
/// providers on recent iOS versions. Using `UIDocumentPickerViewController`
/// with `asCopy: true` gives us local, security-scope-free URLs and also lets
/// the user select folders and ZIP archives.
struct MMDDocumentPicker: UIViewControllerRepresentable {

    let contentTypes: [UTType]
    var allowsMultipleSelection: Bool = true
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: MMDDocumentPicker

        init(parent: MMDDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

enum MMDImportTypes {
    static var pmx: UTType { UTType(filenameExtension: "pmx") ?? .data }
    static var pmd: UTType { UTType(filenameExtension: "pmd") ?? .data }
    static var vmd: UTType { UTType(filenameExtension: "vmd") ?? .data }
    static var vpd: UTType { UTType(filenameExtension: "vpd") ?? .data }
    static var folder: UTType { .folder }
    static var zip: UTType { .zip }

    static var modelImport: [UTType] { [folder, zip, pmx, pmd] }
    static var motionImport: [UTType] { [vmd, zip] }
    static var poseImport: [UTType] { [vpd] }
    static var imageImport: [UTType] { [.image] }
}
