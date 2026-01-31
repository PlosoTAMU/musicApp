import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    
    private let containerView = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let iconImageView = UIImageView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedItems()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        
        // Container
        containerView.backgroundColor = UIColor.systemBackground
        containerView.layer.cornerRadius = 20
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.3
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 10
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        
        // App icon
        iconImageView.image = UIImage(systemName: "arrow.down.circle.fill")
        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(iconImageView)
        
        // Activity indicator
        activityIndicator.color = .systemBlue
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        containerView.addSubview(activityIndicator)
        
        // Status label
        statusLabel.text = "Sending to Pulsor..."
        statusLabel.textColor = .label
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 220),
            containerView.heightAnchor.constraint(equalToConstant: 160),
            
            iconImageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            iconImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            iconImageView.widthAnchor.constraint(equalToConstant: 44),
            iconImageView.heightAnchor.constraint(equalToConstant: 44),
            
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 16),
            
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16)
        ])
        
        // Tap background to cancel
        let tap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
        view.addGestureRecognizer(tap)
    }
    
    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No items found")
            return
        }
        
        let providers = extensionItems
            .compactMap { $0.attachments }
            .flatMap { $0 }
        
        guard !providers.isEmpty else {
            showError("No attachments")
            return
        }
        
        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        
        let group = DispatchGroup()
        var foundURL: String?
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, error in
                    defer { group.leave() }
                    if let url = item as? URL {
                        foundURL = url.absoluteString
                        print("✅ Found URL: \(url.absoluteString)")
                    } else if let error = error {
                        print("❌ Error loading URL: \(error)")
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: textType, options: nil) { item, error in
                    defer { group.leave() }
                    if let text = item as? String {
                        foundURL = Self.extractURL(from: text)
                        print("✅ Extracted URL from text: \(foundURL ?? "none")")
                    } else if let error = error {
                        print("❌ Error loading text: \(error)")
                    }
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            if let urlString = foundURL {
                self.updateStatus("Saving...")
                IncomingShareQueue.enqueue(urlString)
                self.openAppAndFinish(withURL: urlString)
            } else {
                self.showError("No URL found")
            }
        }
    }
    
    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }
    
    private func showError(_ message: String) {
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
            self.iconImageView.image = UIImage(systemName: "xmark.circle.fill")
            self.iconImageView.tintColor = .systemRed
            self.statusLabel.text = message
            self.statusLabel.textColor = .systemRed
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    private func showSuccess() {
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
            self.iconImageView.image = UIImage(systemName: "checkmark.circle.fill")
            self.iconImageView.tintColor = .systemGreen
            self.statusLabel.text = "Opening Pulsor..."
            self.statusLabel.textColor = .systemGreen
        }
    }
    
    private func openAppAndFinish(withURL urlString: String?) {
        var components = URLComponents()
        components.scheme = "musicApp"
        components.host = "import"
        
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.queryItems = [URLQueryItem(name: "url", value: encoded)]
        }
        
        guard let url = components.url else {
            showError("Failed to create URL")
            return
        }
        
        print("🚀 Opening URL: \(url.absoluteString)")
        
        updateStatus("Opening Pulsor...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openURL(url)
        }
    }
    
    private func openURL(_ url: URL) {
        print("🚀 Attempting to open: \(url.absoluteString)")
        
        // Check if we can open the URL
        
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                print(success ? "✅ extensionContext.open succeeded" : "❌ extensionContext.open failed")
                
                if !success {
                    self?.openURLViaResponderChain(url)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
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
                showSuccess()
                print("✅ Opened via responder chain")
                return
            }
            responder = current.next
        }
        print("❌ All methods failed")
    }
    
    private static func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .first?.url?.absoluteString
    }
}
