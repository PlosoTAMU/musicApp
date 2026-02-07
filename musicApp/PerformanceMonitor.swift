import Foundation
import SwiftUI

class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private struct Metric {
        var totalTime: Double = 0
        var averageTime: Double = 0
        var maxTime: Double = 0
        var minTime: Double = .infinity
        var callCount: Int = 0
        var lastUpdated: Date = Date()
        
        mutating func record(_ duration: Double) {
            callCount += 1
            totalTime += duration
            averageTime = totalTime / Double(callCount)
            maxTime = max(maxTime, duration)
            minTime = min(minTime, duration)
            lastUpdated = Date()
        }
    }
    
    private var metrics: [String: Metric] = [:]
    private var timers: [String: CFAbsoluteTime] = [:]
    private let lock = NSLock()
    
    // FPS tracking
    private var frameTimestamps: [CFAbsoluteTime] = []
    private var lastFPSReport: CFAbsoluteTime = 0
    
    private init() {
        #if DEBUG
        // Auto-export stats every 30 seconds
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.exportStats()
        }
        #endif
    }
    
    func start(_ label: String) {
        #if DEBUG
        lock.lock()
        timers[label] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        #endif
    }
    
    func end(_ label: String) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        
        guard let startTime = timers[label] else { return }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000 // ms
        timers.removeValue(forKey: label)
        
        if metrics[label] == nil {
            metrics[label] = Metric()
        }
        metrics[label]?.record(duration)
        
        // Only log extremely slow operations (> 33ms = drops below 30fps)
        if duration > 33 {
            print("🐌 [Perf] \(label): \(String(format: "%.1fms", duration))")
        }
        #endif
    }
    
    func measure<T>(_ label: String, block: () -> T) -> T {
        #if DEBUG
        start(label)
        let result = block()
        end(label)
        return result
        #else
        return block()
        #endif
    }
    
    // Track frame rendering for FPS calculation
    func recordFrame() {
        #if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        frameTimestamps.append(now)
        
        // Keep only last 60 frames
        if frameTimestamps.count > 60 {
            frameTimestamps.removeFirst()
        }
        
        // Report FPS every 5 seconds
        if now - lastFPSReport > 5.0 {
            calculateFPS()
            lastFPSReport = now
        }
        #endif
    }
    
    private func calculateFPS() {
        guard frameTimestamps.count > 1 else { return }
        
        let duration = frameTimestamps.last! - frameTimestamps.first!
        let fps = Double(frameTimestamps.count - 1) / duration
        
        if fps < 30 {
            print("⚠️ [FPS] Low framerate: \(String(format: "%.1f", fps)) fps")
        }
    }
    
    // Export comprehensive statistics
    func exportStats() {
        lock.lock()
        let snapshot = metrics
        lock.unlock()
        
        guard !snapshot.isEmpty else { return }
        
        print("\n" + String(repeating: "=", count: 80))
        print("📊 PERFORMANCE REPORT")
        print(String(repeating: "=", count: 80))
        
        // Calculate FPS
        var currentFPS: Double = 0
        if frameTimestamps.count > 1 {
            let duration = frameTimestamps.last! - frameTimestamps.first!
            currentFPS = Double(frameTimestamps.count - 1) / duration
        }
        print("🎬 Current FPS: \(String(format: "%.1f", currentFPS))")
        
        // Find bottlenecks
        let sortedByAvg = snapshot.sorted { $0.value.averageTime > $1.value.averageTime }
        let sortedByTotal = snapshot.sorted { $0.value.totalTime > $1.value.totalTime }
        let sortedByFrequency = snapshot.sorted { $0.value.callCount > $1.value.callCount }
        
        print("\n🐌 SLOWEST OPERATIONS (by average time):")
        print(String(repeating: "-", count: 80))
        for (label, metric) in sortedByAvg.prefix(5) {
            print(String(format: "  %-35s Avg: %6.2fms  Max: %6.2fms  Min: %6.2fms",
                        label,
                        metric.averageTime,
                        metric.maxTime,
                        metric.minTime))
        }
        
        print("\n⏱️  MOST TIME CONSUMING (by total time):")
        print(String(repeating: "-", count: 80))
        for (label, metric) in sortedByTotal.prefix(5) {
            let percentage = (metric.totalTime / sortedByTotal.reduce(0) { $0 + $1.value.totalTime }) * 100
            print(String(format: "  %-35s Total: %7.1fms  Calls: %5d  (%4.1f%%)",
                        label,
                        metric.totalTime,
                        metric.callCount,
                        percentage))
        }
        
        print("\n🔄 MOST FREQUENT OPERATIONS:")
        print(String(repeating: "-", count: 80))
        for (label, metric) in sortedByFrequency.prefix(5) {
            let callsPerSecond = Double(metric.callCount) / Date().timeIntervalSince(metric.lastUpdated.addingTimeInterval(-30))
            print(String(format: "  %-35s Calls: %5d  Rate: %5.1f/sec",
                        label,
                        metric.callCount,
                        callsPerSecond))
        }
        
        // Key findings
        print("\n💡 KEY FINDINGS:")
        print(String(repeating: "-", count: 80))
        
        if currentFPS < 30 {
            print("  ⚠️  Low framerate detected (\(String(format: "%.1f", currentFPS)) fps)")
        }
        
        if let fftMetric = snapshot["FFT_Processing"] {
            let fftFreq = Double(fftMetric.callCount) / 30.0
            print("  🎵 FFT running at \(String(format: "%.1f", fftFreq)) Hz (target: 30 Hz)")
        }
        
        if let swiftUIMetric = snapshot["FFT_to_SwiftUI"] {
            if swiftUIMetric.averageTime > 10 {
                print("  ⚠️  SwiftUI updates are slow (avg: \(String(format: "%.1f", swiftUIMetric.averageTime))ms)")
            }
        }
        
        let totalOperations = snapshot.values.reduce(0) { $0 + $1.callCount }
        print("  📈 Total operations tracked: \(totalOperations)")
        
        print(String(repeating: "=", count: 80) + "\n")
    }
    
    // Manual export trigger
    func printStats() {
        exportStats()
    }
    
    // Reset all metrics
    func reset() {
        lock.lock()
        metrics.removeAll()
        frameTimestamps.removeAll()
        lock.unlock()
        print("🔄 [Perf] Metrics reset")
    }
}