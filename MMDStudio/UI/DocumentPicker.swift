import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 可靠的 UIKit 文档选择器。
///
/// 在近几个 iOS 版本里，SwiftUI 的 `.fileImporter` 对某些
/// iCloud/Files 提供方看起来毫无反应。改用
/// `UIDocumentPickerViewController` 配合 `asCopy: true`，
/// 拿到本地、无需安全作用域的 URL，还让用户能选目录和 ZIP。
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
