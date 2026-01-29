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

        // We want either a URL item or plain text containing a URL.
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
                self.pingMainApp() // optional but nice
            }
            self.finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func pingMainApp() {
        // Optional: wake the app to process immediately.
        // Requires URL scheme in main app.
        let schemeURL = URL(string: "ploso://import")!
        _ = openURL(schemeURL)
    }

    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while responder != nil {
            if let app = responder as? UIApplication {
                app.performSelector(onMainThread: #selector(UIApplication.open(_:options:completionHandler:)),
                                    with: [url, [:], nil],
                                    waitUntilDone: false)
                return true
            }
            responder = responder?.next
        }
        return false
    }

    private static func firstURLString(in text: String) -> String? {
        // very simple detector; good enough for YouTube shares
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}