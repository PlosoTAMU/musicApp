import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }
    
    // Make the view transparent so it looks like it closes instantly
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            openMainAppAndFinish(withURL: nil)
            return
        }

        let providers = extensionItems
            .compactMap { $0.attachments }
            .flatMap { $0 }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        let group = DispatchGroup()
        var foundURL: String?

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        foundURL = url.absoluteString
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                    defer { group.leave() }
                    if let text = item as? String {
                        foundURL = Self.firstURLString(in: text)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let urlString = foundURL {
                IncomingShareQueue.enqueue(urlString)
            }
            self?.openMainAppAndFinish(withURL: foundURL)
        }
    }

    // FIXED: Use the correct API to open main app from extension
    private func openMainAppAndFinish(withURL urlString: String?) {
        // Encode the URL if we have one, so the app can start downloading immediately
        var urlScheme = "pulsor://import"
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlScheme = "pulsor://import?url=\(encoded)"
        }
        
        guard let url = URL(string: urlScheme) else {
            finish()
            return
        }
        
        // THIS IS THE KEY FIX: Use extensionContext's open method
        extensionContext?.open(url, completionHandler: { [weak self] success in
            if success {
                print("✅ Successfully opened main app")
            } else {
                print("❌ Failed to open main app")
            }
            self?.finish()
        })
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private static func firstURLString(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}