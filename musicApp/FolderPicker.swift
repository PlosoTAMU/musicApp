import SwiftUI
import UniformTypeIdentifiers

struct FolderPicker: UIViewControllerRepresentable {
    @ObservedObject var downloadManager: DownloadManager
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        
        init(_ parent: FolderPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let folderURL = urls.first else { return }
            guard folderURL.startAccessingSecurityScopedResource() else { return }
            defer { folderURL.stopAccessingSecurityScopedResource() }
            
            if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension.lowercased() == "mp3" || fileURL.pathExtension.lowercased() == "m4a" {
                        let name = fileURL.deletingPathExtension().lastPathComponent
                        // Neutralize the name before creating the download
                        let cleanedName = parent.downloadManager.neutralizeName(name)
                        let download = Download(name: cleanedName, url: fileURL)
                        parent.downloadManager.addDownload(download)
                    }
                }
            }
            
            parent.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}