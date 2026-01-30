import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    
    private let containerView = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }
    
    private func setupUI() {
        // Semi-transparent background
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        
        // Container card
        containerView.backgroundColor = UIColor.systemBackground
        containerView.layer.cornerRadius = 16
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        
        // Activity indicator
        activityIndicator.color = .label
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        containerView.addSubview(activityIndicator)
        
        // Status label
        statusLabel.text = "Opening Pulsor..."
        statusLabel.textColor = .label
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 200),
            containerView.heightAnchor.constraint(equalToConstant: 120),
            
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16)
        ])
        
        // Tap outside to dismiss
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        view.addGestureRecognizer(tapGesture)
    }
    
    @objc private func backgroundTapped() {
        completeExtension()
    }
    
    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            updateStatus("No items found")
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
                self?.updateStatus("Opening Pulsor...")
            } else {
                self?.updateStatus("No URL found")
            }
            self?.openAppAndFinish(withURL: foundURL)
        }
    }
    
    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
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
        
        guard let url = components.url else {
            updateStatus("Failed to create URL")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.completeExtension()
            }
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.openURL(url)
        }
    }
    
    private func openURL(_ url: URL) {
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.updateStatus("✓ Opening...")
                } else {
                    self?.updateStatus("Opening app...")
                    self?.openURLViaResponderChain(url)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.completeExtension()
                }
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