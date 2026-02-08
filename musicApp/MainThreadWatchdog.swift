import Foundation
import QuartzCore

/// Detects main thread hangs/stalls
class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    
    private var lastPingTime: CFAbsoluteTime = 0
    private var watchdogTimer: Timer?
    private var responseTimer: Timer?
    private var stallCount = 0
    private let watchdogQueue = DispatchQueue(label: "com.musicapp.watchdog", qos: .utility)
    
    func start() {
        stop()
        lastPingTime = CFAbsoluteTimeGetCurrent()
        
        // Response timer on main thread (should be fast)
        DispatchQueue.main.async { [weak self] in
            self?.responseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.lastPingTime = CFAbsoluteTimeGetCurrent()
            }
        }
        
        // Watchdog timer on background thread to avoid blocking main thread
        watchdogQueue.async { [weak self] in
            guard let self = self else { return }
            
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.checkMainThread()
            }
            self.watchdogTimer = timer
            
            // Add to run loop on background thread
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.run()
        }
    }
    
    private func checkMainThread() {
        let now = CFAbsoluteTimeGetCurrent()
        let stallDuration = (now - lastPingTime) * 1000 // ms
        
        if stallDuration > 100 { // >100ms stall
            stallCount += 1
            print("⚠️ [MainThreadWatchdog] Main thread stalled for \(String(format: "%.0fms", stallDuration))")
            
            // Get main thread stack from background thread
            if Thread.isMainThread {
                print("📍 (Already on main thread - can't get blocked stack)")
            } else {
                print("📍 Check Xcode debugger for main thread stack trace")
            }
        }
    }
    
    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        responseTimer?.invalidate()
        responseTimer = nil
        lastPingTime = 0
    }
    
    func getStallCount() -> Int {
        return stallCount
    }
    
    func reset() {
        stallCount = 0
    }
}
