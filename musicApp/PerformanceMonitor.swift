import Foundation
import SwiftUI
import os.signpost

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
    
    // System metrics tracking
    private struct SystemMetrics {
        var cpuUsage: Double = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var thermalState: ProcessInfo.ThermalState = .nominal
        var timestamp: Date = Date()
    }
    
    private var metrics: [String: Metric] = [:]
    private var timers: [String: CFAbsoluteTime] = [:]
    private let lock = NSLock()
    
    // FPS tracking
    private var frameTimestamps: [CFAbsoluteTime] = []
    private var lastFPSReport: CFAbsoluteTime = 0
    
    // System metrics tracking
    private var systemMetricsHistory: [SystemMetrics] = []
    private var lastSystemMetricsUpdate: CFAbsoluteTime = 0
    
    private init() {
        #if DEBUG
        // Auto-export stats every 30 seconds
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.exportStats()
        }
        
        // Update system metrics every 2 seconds
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateSystemMetrics()
        }
        #endif
    }
    
    // MARK: - System Metrics
    
    private func updateSystemMetrics() {
        let cpu = getCPUUsage()
        let memory = getMemoryUsage()
        let thermal = ProcessInfo.processInfo.thermalState
        
        let metrics = SystemMetrics(
            cpuUsage: cpu,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            thermalState: thermal,
            timestamp: Date()
        )
        
        lock.lock()
        systemMetricsHistory.append(metrics)
        // Keep last 30 samples (1 minute of data at 2 second intervals)
        if systemMetricsHistory.count > 30 {
            systemMetricsHistory.removeFirst()
        }
        lock.unlock()
        
        // Alert on high resource usage
        if cpu > 80 {
            print("⚠️ [System] High CPU usage: \(String(format: "%.1f", cpu))%")
        }
        
        let memoryUsagePercent = Double(memory.used) / Double(memory.total) * 100
        if memoryUsagePercent > 80 {
            print("⚠️ [System] High memory usage: \(String(format: "%.1f", memoryUsagePercent))% (\(formatBytes(memory.used)) / \(formatBytes(memory.total)))")
        }
        
        if thermal == .serious || thermal == .critical {
            print("🔥 [System] High thermal state: \(thermalStateString(thermal))")
        }
    }
    
    private func getCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = task_threads(mach_task_self_, &threadsList, &threadsCount)
        
        if threadsResult == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                
                guard infoResult == KERN_SUCCESS else {
                    continue
                }
                
                let threadBasicInfo = threadInfo as thread_basic_info
                if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                    totalUsageOfCPU += (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
                }
            }
            
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        }
        
        return totalUsageOfCPU
    }
    
    private func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        var used: UInt64 = 0
        if result == KERN_SUCCESS {
            used = UInt64(taskInfo.phys_footprint)
        }
        
        // Get total device memory
        let total = ProcessInfo.processInfo.physicalMemory
        
        return (used, total)
    }
    
    private func getEnergyImpact() -> String {
        // Energy impact is estimated based on CPU, memory, and thermal state
        let avgCPU = systemMetricsHistory.isEmpty ? 0 : systemMetricsHistory.map { $0.cpuUsage }.reduce(0, +) / Double(systemMetricsHistory.count)
        let avgMemory = systemMetricsHistory.isEmpty ? 0 : Double(systemMetricsHistory.map { $0.memoryUsed }.reduce(0, +)) / Double(systemMetricsHistory.count)
        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let avgMemoryPercent = (avgMemory / Double(memoryTotal)) * 100
        
        let thermalState = systemMetricsHistory.last?.thermalState ?? .nominal
        
        // Calculate energy score (0-100)
        var energyScore = avgCPU * 0.6  // CPU is 60% of energy impact
        energyScore += avgMemoryPercent * 0.2  // Memory is 20%
        
        switch thermalState {
        case .nominal:
            energyScore += 0
        case .fair:
            energyScore += 10
        case .serious:
            energyScore += 20
        case .critical:
            energyScore += 30
        @unknown default:
            energyScore += 0
        }
        
        // Classify energy impact
        if energyScore < 20 {
            return "Low"
        } else if energyScore < 50 {
            return "Medium"
        } else if energyScore < 80 {
            return "High"
        } else {
            return "Very High"
        }
    }
    
    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
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
        let systemSnapshot = systemMetricsHistory
        lock.unlock()
        
        print("\n" + String(repeating: "=", count: 80))
        print("📊 PERFORMANCE REPORT")
        print(String(repeating: "=", count: 80))
        
        // System metrics
        if let latest = systemSnapshot.last {
            print("💻 SYSTEM METRICS:")
            let memoryPercent = Double(latest.memoryUsed) / Double(latest.memoryTotal) * 100
            print("   CPU Usage:        \(String(format: "%.1f", latest.cpuUsage))%")
            print("   Memory:           \(formatBytes(latest.memoryUsed)) / \(formatBytes(latest.memoryTotal)) (\(String(format: "%.1f", memoryPercent))%)")
            print("   Thermal State:    \(thermalStateString(latest.thermalState))")
            print("   Energy Impact:    \(getEnergyImpact())")
            
            // Average CPU over last minute
            if systemSnapshot.count > 1 {
                let avgCPU = systemSnapshot.map { $0.cpuUsage }.reduce(0, +) / Double(systemSnapshot.count)
                let maxCPU = systemSnapshot.map { $0.cpuUsage }.max() ?? 0
                print("   Avg CPU (1 min):  \(String(format: "%.1f", avgCPU))% (peak: \(String(format: "%.1f", maxCPU))%)")
            }
            print("")
        }
        
        guard !snapshot.isEmpty else {
            print("No performance metrics recorded yet.")
            print(String(repeating: "=", count: 80) + "\n")
            return
        }
        
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
        systemMetricsHistory.removeAll()
        lastFPSReport = CFAbsoluteTimeGetCurrent()
        lastSystemMetricsUpdate = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        print("🔄 [PerformanceMonitor] Metrics reset")
    }
    
    // Get current system metrics on-demand
    func getCurrentSystemMetrics() -> (cpu: Double, memory: String, thermal: String, energy: String) {
        let cpu = getCPUUsage()
        let memory = getMemoryUsage()
        let memoryStr = "\(formatBytes(memory.used)) / \(formatBytes(memory.total))"
        let thermal = thermalStateString(ProcessInfo.processInfo.thermalState)
        let energy = getEnergyImpact()
        return (cpu, memoryStr, thermal, energy)
    }
}