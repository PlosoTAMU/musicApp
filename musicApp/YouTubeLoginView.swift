import SwiftUI
import WebKit

/// A view that displays YouTube login and captures cookies for authenticated requests
struct YouTubeLoginView: View {
    @ObservedObject var extractor: YouTubeExtractor
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ZStack {
                YouTubeLoginWebView(extractor: extractor, isLoading: $isLoading)
                
                if isLoading {
                    ProgressView("Loading...")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                }
            }
            .navigationTitle("Sign in to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if extractor.isLoggedIn {
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.bold)
                    }
                }
            }
        }
    }
}

/// WKWebView wrapper for YouTube login
struct YouTubeLoginWebView: UIViewRepresentable {
    @ObservedObject var extractor: YouTubeExtractor
    @Binding var isLoading: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use default (persistent) data store so cookies are saved
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // Load YouTube login
        if let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&continue=https://www.youtube.com/") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: YouTubeLoginWebView
        
        init(_ parent: YouTubeLoginWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            
            // Check if we're on YouTube (meaning login succeeded)
            if let url = webView.url?.absoluteString {
                print("🌐 [YouTubeLogin] Current URL: \(url)")
                
                if url.contains("youtube.com") && !url.contains("accounts.google") {
                    // We landed on YouTube - check for login cookies
                    checkAndSaveCookies(webView: webView)
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            print("❌ [YouTubeLogin] Navigation failed: \(error.localizedDescription)")
        }
        
        private func checkAndSaveCookies(webView: WKWebView) {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let youtubeCookies = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
                
                print("🍪 [YouTubeLogin] Found \(youtubeCookies.count) YouTube/Google cookies")
                
                // Check for login indicators
                let loginCookies = ["SID", "SSID", "HSID", "LOGIN_INFO", "APISID", "SAPISID"]
                let hasLoginCookies = youtubeCookies.contains { loginCookies.contains($0.name) }
                
                if hasLoginCookies {
                    print("✅ [YouTubeLogin] Login cookies found!")
                    
                    // Save cookies to HTTPCookieStorage for URLSession to use
                    for cookie in youtubeCookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    
                    DispatchQueue.main.async {
                        self.parent.extractor.isLoggedIn = true
                        self.parent.extractor.needsLogin = false
                    }
                }
            }
        }
    }
}
