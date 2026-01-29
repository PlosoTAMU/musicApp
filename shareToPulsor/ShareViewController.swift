import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
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

        group.notify(queue: .main) {
            if let urlString = foundURL {
                IncomingShareQueue.enqueue(urlString)
                
                // FIXED: Open main app immediately
                if let appURL = URL(string: "pulsor://import") {
                    self.openURL(appURL)
                }
            }
            self.finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while let currentResponder = responder {
            if let application = currentResponder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = currentResponder.next
        }
    }

    private static func firstURLString(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}