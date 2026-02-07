import Foundation
import SwiftUI

/// Lightweight performance profiler for identifying bottlenecks
class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private struct Metric {
        var averageTime: Double = 0
        var maxTime: Double = 0
        var callCount: Int = 0
        var lastUpdated: Date = Date()
        
        mutating func record(_ duration: Double) {
            callCount += 1
            averageTime = ((averageTime * Double(callCount - 1)) + duration) / Double(callCount)
            maxTime = max(maxTime, duration)
            lastUpdated = Date()
        }
    }
    
    private var metrics: [String: Metric] = [:]
    private var timers: [String: CFAbsoluteTime] = [:]
    private let lock = NSLock()
    
    private init() {
        // Print summary every 30 seconds in debug builds
        #if DEBUG
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.printSummary()
        }
        #endif
    }
    
    func start(_ label: String) {
        lock.lock()
        timers[label] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }
    
    func end(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let startTime = timers[label] else { return }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000 // ms
        timers.removeValue(forKey: label)
        
        if metrics[label] == nil {
            metrics[label] = Metric()
        }
        metrics[label]?.record(duration)
        
        // Log slow operations (> 16ms drops below 60fps)
        if duration > 16 {
            print("⚠️ [Perf] \(label): \(String(format: "%.2fms", duration))")
        }
    }
    
    func measure<T>(_ label: String, block: () -> T) -> T {
        start(label)
        let result = block()
        end(label)
        return result
    }
    
    private func printSummary() {
        lock.lock()
        let snapshot = metrics
        lock.unlock()
        
        guard !snapshot.isEmpty else { return }
        
        print("\n📊 [Performance Summary - Top 10 Slowest Operations]")
        print(String(repeating: "=", count: 80))
        
        let sorted = snapshot.sorted { $0.value.averageTime > $1.value.averageTime }
        for (label, metric) in sorted.prefix(10) {
            print(String(format: "%-40s Avg: %6.2fms  Max: %6.2fms  Count: %d",
                        label,
                        metric.averageTime,
                        metric.maxTime,
                        metric.callCount))
        }
        print(String(repeating: "=", count: 80) + "\n")
    }
}