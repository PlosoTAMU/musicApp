import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Make background transparent so popup is minimal
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            openAppAndFinish(withURL: nil)
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
                        foundURL = Self.extractURL(from: text)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let urlString = foundURL {
                IncomingShareQueue.enqueue(urlString)
            }
            self?.openAppAndFinish(withURL: foundURL)
        }
    }

    private func openAppAndFinish(withURL urlString: String?) {
        // Build URL with the shared link as parameter
        var components = URLComponents()
        components.scheme = "pulsor"  // CHANGE THIS to match your URL scheme
        components.host = "import"
        
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.queryItems = [URLQueryItem(name: "url", value: encoded)]
        }
        
        guard let url = components.url else {
            completeExtension()
            return
        }
        
        // CRITICAL: Use a small delay to let the UI settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openURL(url)
        }
    }
    
    private func openURL(_ url: URL) {
        // Method 1: Try extensionContext.open (works on iOS 13+)
        extensionContext?.open(url) { [weak self] success in
            if success {
                print("✅ Opened app via extensionContext")
            } else {
                print("❌ extensionContext.open failed, trying fallback")
                // Method 2: Fallback using responder chain
                self?.openURLViaResponderChain(url)
            }
            
            // Complete after a short delay to ensure URL opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.completeExtension()
            }
        }
    }
    
    private func openURLViaResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    private func completeExtension() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private static func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}