import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }
    
    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            completeAndOpenApp(urlString: nil)
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
            self?.completeAndOpenApp(urlString: foundURL)
        }
    }
    
    private func completeAndOpenApp(urlString: String?) {
        // STEP 1: Save URL to shared container (app group)
        if let urlString = urlString {
            IncomingShareQueue.enqueue(urlString)
            print("✅ Enqueued: \(urlString)")
        }
        
        // STEP 2: Build the custom URL scheme
        var components = URLComponents()
        components.scheme = "pulsor"
        components.host = "import"
        
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.queryItems = [URLQueryItem(name: "url", value: encoded)]
        }
        
        guard let openURL = components.url else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        
        // STEP 3: Open URL using the only reliable method for share extensions
        openURLInApp(openURL)
    }
    
    private func openURLInApp(_ url: URL) {
        // This is the ONLY reliable way to open a URL from a share extension
        var responder: UIResponder? = self as UIResponder
        let selector = sel_registerName("openURL:")
        
        while responder != nil {
            if responder!.responds(to: selector) {
                // Found a responder that can open URLs
                _ = responder!.perform(selector, with: url)
                break
            }
            responder = responder?.next
        }
        
        // Complete the extension after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
    
    private static func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}