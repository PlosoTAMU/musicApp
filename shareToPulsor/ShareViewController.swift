import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    
    private let containerView = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let iconImageView = UIImageView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("🟢 viewDidLoad")
        setupUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("🟢 viewDidAppear")
        handleSharedItems()
    }
    
    private func setupUI() {
        print("🎨 setupUI")
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        
        containerView.backgroundColor = UIColor.systemBackground
        containerView.layer.cornerRadius = 20
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.3
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 10
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        
        iconImageView.image = UIImage(systemName: "arrow.down.circle.fill")
        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(iconImageView)
        
        activityIndicator.color = .systemBlue
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        containerView.addSubview(activityIndicator)
        
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
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
        view.addGestureRecognizer(tap)
    }
    
    @objc private func cancelTapped() {
        print("🛑 User tapped cancel")
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    private func handleSharedItems() {
        print("📦 handleSharedItems")
        
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            print("❌ No extension items")
            showError("No items found")
            return
        }
        
        print("📦 Extension items count: \(extensionItems.count)")
        
        let providers = extensionItems
            .compactMap { $0.attachments }
            .flatMap { $0 }
        
        print("📎 Total item providers: \(providers.count)")
        
        guard !providers.isEmpty else {
            showError("No attachments")
            return
        }
        
        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        
        let group = DispatchGroup()
        var foundURL: String?
        
        for (index, provider) in providers.enumerated() {
            print("🔍 Inspecting provider \(index)")
            
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                print("➡️ Provider has URL type")
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, error in
                    defer {
                        print("⬅️ Leaving group (URL)")
                        group.leave()
                    }
                    
                    if let url = item as? URL {
                        foundURL = url.absoluteString
                        print("✅ Loaded URL: \(url.absoluteString)")
                    } else if let error = error {
                        print("❌ Error loading URL: \(error)")
                    } else {
                        print("⚠️ URL item was nil or unexpected type")
                    }
                }
                
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                print("➡️ Provider has text type")
                group.enter()
                provider.loadItem(forTypeIdentifier: textType, options: nil) { item, error in
                    defer {
                        print("⬅️ Leaving group (Text)")
                        group.leave()
                    }
                    
                    if let text = item as? String {
                        print("📝 Loaded text: \(text)")
                        foundURL = Self.extractURL(from: text)
                        print("🔗 Extracted URL: \(foundURL ?? "nil")")
                    } else if let error = error {
                        print("❌ Error loading text: \(error)")
                    } else {
                        print("⚠️ Text item was nil or unexpected type")
                    }
                }
            } else {
                print("🚫 Provider does not support URL or text")
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            print("📢 DispatchGroup completed")
            guard let self = self else { return }
            
            if let urlString = foundURL {
                print("🎯 Final URL selected: \(urlString)")
                self.updateStatus("Saving...")
                IncomingShareQueue.enqueue(urlString)
                self.openAppAndFinish(withURL: urlString)
            } else {
                print("❌ No URL found after processing all providers")
                self.showError("No URL found")
            }
        }
    }
    
    private func updateStatus(_ text: String) {
        print("ℹ️ Status update: \(text)")
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }
    
    private func showError(_ message: String) {
        print("🧨 showError: \(message)")
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
            self.iconImageView.image = UIImage(systemName: "xmark.circle.fill")
            self.iconImageView.tintColor = .systemRed
            self.statusLabel.text = message
            self.statusLabel.textColor = .systemRed
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("🧨 Completing extension after error")
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    private func showSuccess() {
        print("🎉 showSuccess")
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
            self.iconImageView.image = UIImage(systemName: "checkmark.circle.fill")
            self.iconImageView.tintColor = .systemGreen
            self.statusLabel.text = "Opening Pulsor..."
            self.statusLabel.textColor = .systemGreen
        }
    }
    
    private func openAppAndFinish(withURL urlString: String?) {
        print("🚀 Preparing to open app with URL: \(urlString ?? "nil")")
        
        var components = URLComponents()
        components.scheme = "musicApp"
        components.host = "import"
        
        if let urlString = urlString,
           let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.queryItems = [URLQueryItem(name: "url", value: encoded)]
        }
        
        guard let url = components.url else {
            print("❌ Failed to create deep link URL")
            showError("Failed to create URL")
            return
        }
        
        print("🔗 Deep link URL: \(url.absoluteString)")
        updateStatus("Opening Pulsor...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openURL(url)
        }
    }
    
    private func openURL(_ url: URL) {
        print("🌍 Attempting extensionContext.open")
        
        extensionContext?.open(url) { [weak self] success in
            print(success ? "✅ extensionContext.open succeeded" : "❌ extensionContext.open failed")
            
            if !success {
                print("↩️ Falling back to responder chain")
                self?.openURLViaResponderChain(url)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                print("🏁 Completing extension request")
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    private func openURLViaResponderChain(_ url: URL) {
        print("🔄 Trying responder chain")
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        
        while let current = responder {
            if current.responds(to: selector) {
                print("✅ Responder found: \(type(of: current))")
                current.perform(selector, with: url)
                showSuccess()
                return
            }
            responder = current.next
        }
        
        print("❌ Responder chain failed")
    }
    
    private static func extractURL(from text: String) -> String? {
        print("🔎 Running NSDataDetector")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?
            .matches(in: text, options: [], range: range)
            .first?
            .url?
            .absoluteString
    }
}
