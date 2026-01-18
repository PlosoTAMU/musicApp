private let apiBaseURL = "https://yt-dlp-api.fly.dev"

func downloadAudio(from youtubeURL: String, completion: @escaping (Track?) -> Void) {
    guard let encodedURL = youtubeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        errorMessage = "Invalid URL"
        completion(nil)
        return
    }
    
    isDownloading = true
    errorMessage = nil
    
    let apiURL = URL(string: "\(apiBaseURL)/api/info?url=\(encodedURL)")!
    
    URLSession.shared.dataTask(with: apiURL) { [weak self] data, response, error in
        guard let self = self else { return }
        
        if let error = error {
            DispatchQueue.main.async {
                self.errorMessage = "Network error: \(error.localizedDescription)"
                self.isDownloading = false
            }
            completion(nil)
            return
        }
        
        guard let data = data else {
            DispatchQueue.main.async {
                self.errorMessage = "No data received"
                self.isDownloading = false
            }
            completion(nil)
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            if let error = json?["error"] as? String {
                DispatchQueue.main.async {
                    self.errorMessage = error
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            guard let title = json?["title"] as? String,
                  let formats = json?["formats"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    self.errorMessage = "Invalid response"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            // Find best audio format
            let audioFormats = formats.filter { format in
                (format["audio_ext"] as? String) != "none" && 
                (format["video_ext"] as? String) == "none"
            }
            
            guard let bestAudio = audioFormats.first,
                  let urlString = bestAudio["url"] as? String,
                  let streamURL = URL(string: urlString) else {
                DispatchQueue.main.async {
                    self.errorMessage = "No audio stream found"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            self.downloadFile(from: streamURL, title: title, completion: completion)
            
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to parse response"
                self.isDownloading = false
            }
            completion(nil)
        }
    }.resume()
}