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
                print("✅ Saved URL to shared container: \(urlString)")
            }
            self?.openAppAndFinish(withURL: foundURL)
        }
    }
    
    private func openAppAndFinish(withURL urlString: String?) {
        var components = URLComponents()
        components.scheme = "pulsor"
        components.host = "import"
        
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.queryItems = [URLQueryItem(name: "url", value: encoded)]
        }
        
        guard let openURL = components.url else {
            completeExtension()
            return
        }
        
        print("🚀 Attempting to open: \(openURL.absoluteString)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.tryOpenURL(openURL)
        }
    }
    
    private func tryOpenURL(_ url: URL) {
        extensionContext?.open(url) { [weak self] success in
            print(success ? "✅ Opened app successfully" : "❌ Failed to open app")
            
            if !success {
                self?.openURLViaResponderChain(url)
            }
            
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
                print("✅ Opened via responder chain")
                return
            }
            responder = current.next
        }
        print("❌ Responder chain fallback failed")
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