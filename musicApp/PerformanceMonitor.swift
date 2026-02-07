import Foundation
import SwiftUI

/// Lightweight performance profiler for identifying bottlenecks
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
        print("")
        
        // Top 10 slowest by average
        print("⏱️  SLOWEST OPERATIONS (by average time):")
        let sortedByAvg = snapshot.sorted { $0.value.averageTime > $1.value.averageTime }
        for (label, metric) in sortedByAvg.prefix(10) {
            let paddedLabel = label.padding(toLength: 35, withPad: " ", startingAt: 0)
            let avgStr = String(format: "%6.2fms", metric.averageTime)
            let maxStr = String(format: "%6.2fms", metric.maxTime)
            let minStr = String(format: "%6.2fms", metric.minTime)
            print("   \(paddedLabel) Avg: \(avgStr)  Max: \(maxStr)  Min: \(minStr)  Count: \(metric.callCount)")
        }
        print("")
        
        // Top 5 by total time (biggest time sinks)
        print("🔥 BIGGEST TIME SINKS (by total time):")
        let sortedByTotal = snapshot.sorted { $0.value.totalTime > $1.value.totalTime }
        for (label, metric) in sortedByTotal.prefix(5) {
            let paddedLabel = label.padding(toLength: 35, withPad: " ", startingAt: 0)
            let totalStr = String(format: "%8.1fms", metric.totalTime)
            let pct = (metric.totalTime / sortedByTotal.first!.value.totalTime) * 100
            print("   \(paddedLabel) Total: \(totalStr)  (\(String(format: "%.1f", pct))%)")
        }
        print("")
        
        // Identify potential bottlenecks
        print("🚨 POTENTIAL BOTTLENECKS:")
        var bottlenecks = 0
        for (label, metric) in snapshot {
            if metric.averageTime > 16 {
                bottlenecks += 1
                print("   • \(label): \(String(format: "%.1fms", metric.averageTime)) avg (drops below 60fps)")
            }
        }
        if bottlenecks == 0 {
            print("   ✅ None detected - all operations under 16ms")
        }
        
        print(String(repeating: "=", count: 80) + "\n")
    }
    
    // Manual export for on-demand statistics
    func printStatsNow() {
        exportStats()
    }
    
    // Reset all metrics (useful for testing specific scenarios)
    func reset() {
        lock.lock()
        metrics.removeAll()
        frameTimestamps.removeAll()
        lastFPSReport = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        print("🔄 [PerformanceMonitor] Metrics reset")
    }
}