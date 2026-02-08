import Foundation
import QuartzCore

/// Detects main thread hangs/stalls
class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    
    private var lastPingTime: CFAbsoluteTime = 0
    private var watchdogTimer: Timer?
    private var stallCount = 0
    
    func start() {
        lastPingTime = CFAbsoluteTimeGetCurrent()
        
        // Ping main thread every 100ms
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkMainThread()
        }
        
        // Respond from main thread
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.lastPingTime = CFAbsoluteTimeGetCurrent()
        }
    }
    
    private func checkMainThread() {
        let now = CFAbsoluteTimeGetCurrent()
        let stallDuration = (now - lastPingTime) * 1000 // ms
        
        if stallDuration > 100 { // >100ms stall
            stallCount += 1
            print("⚠️ [MainThreadWatchdog] Main thread stalled for \(String(format: "%.0fms", stallDuration))")
            
            // Print call stack
            let symbols = Thread.callStackSymbols
            print("📍 Call stack at stall detection:")
            for (i, symbol) in symbols.prefix(10).enumerated() {
                print("  \(i): \(symbol)")
            }
        }
    }
    
    func getStallCount() -> Int {
        return stallCount
    }
    
    func reset() {
        stallCount = 0
    }
}
