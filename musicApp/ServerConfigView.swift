import SwiftUI

struct ServerConfigView: View {
    @ObservedObject var ytdlpService = PythonYTDLPService.shared
    @State private var serverAddress: String = ""
    @State private var isChecking = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("yt-dlp Server")
                            .font(.headline)
                        
                        Text("Run the Python server on your computer, then enter the address here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Server Address")) {
                    HStack {
                        TextField("e.g., 192.168.1.100:8765", text: $serverAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.numbersAndPunctuation)
                        
                        if isChecking {
                            ProgressView()
                                .padding(.leading, 8)
                        }
                    }
                    
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Image(systemName: "network")
                            Text("Test Connection")
                        }
                    }
                    .disabled(serverAddress.isEmpty || isChecking)
                }
                
                Section {
                    HStack {
                        Image(systemName: ytdlpService.isRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(ytdlpService.isRunning ? .green : .red)
                        Text(ytdlpService.statusMessage.isEmpty ? (ytdlpService.isRunning ? "Connected" : "Not connected") : ytdlpService.statusMessage)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Setup Instructions")) {
                    VStack(alignment: .leading, spacing: 8) {
                        instructionRow(number: "1", text: "On your computer, install Python 3")
                        instructionRow(number: "2", text: "Install yt-dlp: pip install yt-dlp")
                        instructionRow(number: "3", text: "Run the server script: python server.py")
                        instructionRow(number: "4", text: "Enter the IP address shown by the server")
                        instructionRow(number: "5", text: "Make sure your phone is on the same WiFi")
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                }
                
                Section {
                    Button {
                        saveAndDismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(serverAddress.isEmpty)
                }
            }
            .navigationTitle("Server Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                serverAddress = ytdlpService.serverAddress
            }
        }
    }
    
    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top) {
            Text(number + ".")
                .fontWeight(.bold)
                .frame(width: 20)
            Text(text)
        }
    }
    
    private func testConnection() {
        isChecking = true
        ytdlpService.setServerAddress(serverAddress)
        
        Task {
            _ = await ytdlpService.checkHealth()
            DispatchQueue.main.async {
                isChecking = false
            }
        }
    }
    
    private func saveAndDismiss() {
        ytdlpService.setServerAddress(serverAddress)
        dismiss()
    }
}

#Preview {
    ServerConfigView()
}
