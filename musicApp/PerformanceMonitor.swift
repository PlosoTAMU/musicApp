import Foundation
import SwiftUI
import os.signpost

/// Intensive performance profiler — deep CPU/battery/thread analysis
class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    // MARK: - Operation Tracking
    
    enum Category: String, CaseIterable {
        case audio      = "🔊 Audio"
        case rendering  = "🎨 Rendering"
        case io         = "💾 I/O"
        case ui         = "📱 UI"
        case system     = "⚙️ System"
    }
    
    private struct Metric {
        var totalTime: Double = 0       // ms
        var averageTime: Double = 0     // ms
        var maxTime: Double = 0         // ms
        var minTime: Double = .infinity // ms
        var callCount: Int = 0
        var recentTimes: [Double] = []  // last 60 samples for rolling avg
        var category: Category = .system
        
        mutating func record(_ duration: Double) {
            callCount += 1
            totalTime += duration
            averageTime = totalTime / Double(callCount)
            maxTime = max(maxTime, duration)
            minTime = min(minTime, duration)
            recentTimes.append(duration)
            if recentTimes.count > 60 { recentTimes.removeFirst() }
        }
        
        var recentAverage: Double {
            guard !recentTimes.isEmpty else { return 0 }
            return recentTimes.reduce(0, +) / Double(recentTimes.count)
        }
        
        var recentMax: Double {
            recentTimes.max() ?? 0
        }
    }
    
    // MARK: - Thread CPU Tracking
    
    private struct ThreadSnapshot {
        var threadID: UInt64
        var cpuUsage: Double
        var name: String
        var userTime: Double
        var systemTime: Double
    }
    
    // MARK: - Energy Model
    
    private struct EnergySnapshot {
        var timestamp: CFAbsoluteTime
        var cpuUsage: Double
        var threadCount: Int
        var memoryMB: Double
        var thermalState: ProcessInfo.ThermalState
        var activeThreadCPU: [String: Double]
        var estimatedWatts: Double
    }
    
    // MARK: - State
    
    private var metrics: [String: Metric] = [:]
    private var timers: [String: CFAbsoluteTime] = [:]
    private var categoryMap: [String: Category] = [:]
    private let lock = NSLock()
    
    // FPS tracking (high precision)
    private var frameTimestamps: [CFAbsoluteTime] = []
    private var frameDurations: [Double] = []
    private var droppedFrameCount: Int = 0
    private var totalFrameCount: Int = 0
    
    // Energy & CPU history
    private var energyHistory: [EnergySnapshot] = []
    private var reportTimer: Timer?
    private var metricsTimer: Timer?
    
    // Visualization callback tracking
    private var vizCallbackTimestamps: [CFAbsoluteTime] = []
    private var vizCallbackRate: Double = 0
    
    // Report interval tracking
    private var lastReportTime: CFAbsoluteTime = 0
    
    private init() {
        #if DEBUG
        lastReportTime = CFAbsoluteTimeGetCurrent()
        
        // High-frequency system metrics (every 1s for granular CPU tracking)
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleSystemMetrics()
        }
        
        // Detailed report every 30 seconds
        reportTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.exportStats()
        }
        #endif
    }
    
    // MARK: - Category Registration
    
    func registerCategory(_ label: String, _ category: Category) {
        lock.lock()
        categoryMap[label] = category
        lock.unlock()
    }
    
    // MARK: - Operation Timing
    
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
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        timers.removeValue(forKey: label)
        
        if metrics[label] == nil {
            metrics[label] = Metric()
            metrics[label]?.category = categoryMap[label] ?? inferCategory(label)
        }
        metrics[label]?.record(duration)
        
        if duration > 16.67 {
            print("🐌 [\(label)] \(String(format: "%.1fms", duration)) — exceeds 60fps frame budget!")
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
    
    // MARK: - FPS Tracking
    
    func recordFrame() {
        #if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        totalFrameCount += 1
        
        if let last = frameTimestamps.last {
            let dt = (now - last) * 1000
            frameDurations.append(dt)
            if frameDurations.count > 120 { frameDurations.removeFirst() }
            if dt > 20.0 { droppedFrameCount += 1 }
        }
        
        frameTimestamps.append(now)
        if frameTimestamps.count > 120 { frameTimestamps.removeFirst() }
        #endif
    }
    
    // MARK: - Visualization Callback Tracking
    
    func recordVisualizationCallback() {
        #if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        vizCallbackTimestamps.append(now)
        if vizCallbackTimestamps.count > 60 { vizCallbackTimestamps.removeFirst() }
        if vizCallbackTimestamps.count > 1 {
            let span = now - vizCallbackTimestamps.first!
            vizCallbackRate = Double(vizCallbackTimestamps.count - 1) / span
        }
        lock.unlock()
        #endif
    }
    
    // MARK: - System Metrics Sampling
    
    private func sampleSystemMetrics() {
        let threads = getPerThreadCPU()
        let totalCPU = threads.reduce(0.0) { $0 + $1.cpuUsage }
        let memory = getMemoryUsage()
        let memoryMB = Double(memory.used) / (1024 * 1024)
        let thermal = ProcessInfo.processInfo.thermalState
        
        var threadMap: [String: Double] = [:]
        let sorted = threads.sorted { $0.cpuUsage > $1.cpuUsage }
        for t in sorted.prefix(8) where t.cpuUsage > 1.0 {
            threadMap[t.name] = t.cpuUsage
        }
        
        let cpuWatts = totalCPU * 0.005
        let estimatedWatts = 0.3 + cpuWatts + 0.8 + 0.1
        
        let snapshot = EnergySnapshot(
            timestamp: CFAbsoluteTimeGetCurrent(),
            cpuUsage: totalCPU,
            threadCount: threads.count,
            memoryMB: memoryMB,
            thermalState: thermal,
            activeThreadCPU: threadMap,
            estimatedWatts: estimatedWatts
        )
        
        lock.lock()
        energyHistory.append(snapshot)
        if energyHistory.count > 60 { energyHistory.removeFirst() }
        lock.unlock()
        
        if totalCPU > 100 {
            let topConsumers = threadMap.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key):\(String(format: "%.0f%%", $0.value))" }.joined(separator: ", ")
            print("⚠️ [CPU] \(String(format: "%.0f%%", totalCPU)) — top: \(topConsumers)")
        }
        
        if thermal == .serious || thermal == .critical {
            print("🔥 [Thermal] \(thermalStateString(thermal)) — CPU will be throttled!")
        }
    }
    
    // MARK: - Per-Thread CPU
    
    private func getPerThreadCPU() -> [ThreadSnapshot] {
        var result: [ThreadSnapshot] = []
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = task_threads(mach_task_self_, &threadsList, &threadsCount)
        
        guard threadsResult == KERN_SUCCESS, let threadsList = threadsList else { return result }
        
        for index in 0..<Int(threadsCount) {
            var basicInfo = thread_basic_info()
            var basicInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let basicResult = withUnsafeMutablePointer(to: &basicInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threadsList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &basicInfoCount)
                }
            }
            
            guard basicResult == KERN_SUCCESS else { continue }
            guard basicInfo.flags & TH_FLAGS_IDLE == 0 else { continue }
            
            let cpuPercent = (Double(basicInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            let userSec = Double(basicInfo.user_time.seconds) + Double(basicInfo.user_time.microseconds) / 1_000_000.0
            let sysSec = Double(basicInfo.system_time.seconds) + Double(basicInfo.system_time.microseconds) / 1_000_000.0
            
            // Get thread name
            var extInfo = thread_extended_info()
            var extInfoCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
            var name = "Thread-\(index)"
            let extResult = withUnsafeMutablePointer(to: &extInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threadsList[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extInfoCount)
                }
            }
            if extResult == KERN_SUCCESS {
                let rawName = withUnsafePointer(to: extInfo.pth_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 64) { charPtr in
                        String(cString: charPtr)
                    }
                }
                if !rawName.isEmpty {
                    name = rawName
                }
            }
            
            // Classify thread names
            if name.contains("com.apple.audio") || name.contains("AVAudioEngine") || name.contains("HAL") || name.contains("AURemoteIO") {
                name = "AudioEngine"
            } else if name.contains("com.apple.main-thread") || index == 0 {
                name = "Main"
            } else if name.contains("com.apple.CoreAnimation") || name.contains("CA") {
                name = "CoreAnimation"
            } else if name.contains("com.apple.metal") || name.contains("MTL") {
                name = "Metal/GPU"
            } else if name.contains("com.apple.NSURLSession") || name.contains("network") {
                name = "Networking"
            } else if name.contains("dispatch") || name.contains("libdispatch") {
                name = "GCD-\(index)"
            }
            
            result.append(ThreadSnapshot(
                threadID: UInt64(index),
                cpuUsage: cpuPercent,
                name: name,
                userTime: userSec,
                systemTime: sysSec
            ))
        }
        
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: threadsList)),
                      vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        
        return result
    }
    
    // MARK: - Memory
    
    private func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let used: UInt64 = result == KERN_SUCCESS ? UInt64(taskInfo.phys_footprint) : 0
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
    
    // MARK: - Helpers
    
    private func inferCategory(_ label: String) -> Category {
        let lower = label.lowercased()
        if lower.contains("audio") || lower.contains("fft") || lower.contains("beat") || lower.contains("viz") || lower.contains("process") {
            return .audio
        } else if lower.contains("render") || lower.contains("draw") || lower.contains("canvas") || lower.contains("frame") {
            return .rendering
        } else if lower.contains("download") || lower.contains("load") || lower.contains("save") || lower.contains("disk") || lower.contains("file") {
            return .io
        } else if lower.contains("ui") || lower.contains("view") || lower.contains("layout") || lower.contains("thumbnail") {
            return .ui
        }
        return .system
    }
    
    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal ✅"
        case .fair: return "Fair ⚠️"
        case .serious: return "Serious 🔥"
        case .critical: return "Critical 🚨"
        @unknown default: return "Unknown"
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    // MARK: - Comprehensive Report
    
    func exportStats() {
        lock.lock()
        let metricsSnapshot = metrics
        let energySnapshot = energyHistory
        let fpsTimestampsSnap = frameTimestamps
        let fpsDurations = frameDurations
        let dropped = droppedFrameCount
        let totalFrames = totalFrameCount
        let vizRate = vizCallbackRate
        lock.unlock()
        
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReportTime
        lastReportTime = now
        
        print("\n" + String(repeating: "═", count: 80))
        print("📊 DEEP PERFORMANCE & ENERGY REPORT")
        print("   Window: \(String(format: "%.0fs", elapsed))")
        print(String(repeating: "═", count: 80))
        
        // ── 1. SYSTEM OVERVIEW ──
        if let latest = energySnapshot.last {
            print("\n┌─ 💻 SYSTEM OVERVIEW ─────────────────────────────────")
            print("│  CPU (now):       \(String(format: "%.1f%%", latest.cpuUsage))")
            
            if energySnapshot.count > 1 {
                let cpus = energySnapshot.map { $0.cpuUsage }
                let avg = cpus.reduce(0, +) / Double(cpus.count)
                let peak = cpus.max() ?? 0
                let minCPU = cpus.min() ?? 0
                print("│  CPU (avg/peak):  \(String(format: "%.1f%%", avg)) / \(String(format: "%.1f%%", peak))")
                print("│  CPU (min):       \(String(format: "%.1f%%", minCPU))")
            }
            
            print("│  Memory:          \(String(format: "%.1f MB", latest.memoryMB))")
            print("│  Thermal:         \(thermalStateString(latest.thermalState))")
            print("│  Active Threads:  \(latest.threadCount)")
            print("│  Est. Power:      \(String(format: "%.2f W", latest.estimatedWatts))")
            print("└──────────────────────────────────────────────────────")
        }
        
        // ── 2. PER-THREAD CPU BREAKDOWN ──
        if let latest = energySnapshot.last, !latest.activeThreadCPU.isEmpty {
            print("\n┌─ 🧵 THREAD CPU BREAKDOWN ────────────────────────────")
            let sorted = latest.activeThreadCPU.sorted { $0.value > $1.value }
            for (name, cpu) in sorted {
                let barLen = min(40, Int(cpu / 2.5))
                let bar = String(repeating: "█", count: max(0, barLen))
                let pad = name.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("│  \(pad) \(String(format: "%5.1f%%", cpu)) \(bar)")
            }
            
            if energySnapshot.count > 5 {
                print("│")
                print("│  📈 THREAD AVERAGES (last \(energySnapshot.count)s):")
                var threadTotals: [String: (sum: Double, count: Int)] = [:]
                for snap in energySnapshot {
                    for (name, cpu) in snap.activeThreadCPU {
                        if threadTotals[name] == nil { threadTotals[name] = (0, 0) }
                        threadTotals[name]!.sum += cpu
                        threadTotals[name]!.count += 1
                    }
                }
                let avgThreads = threadTotals.map { (name: $0.key, avg: $0.value.sum / Double($0.value.count)) }
                    .sorted { $0.avg > $1.avg }
                for t in avgThreads.prefix(6) {
                    let pad = t.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                    print("│    \(pad) avg \(String(format: "%5.1f%%", t.avg))")
                }
            }
            print("└──────────────────────────────────────────────────────")
        }
        
        // ── 3. FPS ANALYSIS ──
        print("\n┌─ 🎬 FRAME RATE ANALYSIS ─────────────────────────────")
        if fpsTimestampsSnap.count > 1 {
            let span = fpsTimestampsSnap.last! - fpsTimestampsSnap.first!
            let fps = span > 0 ? Double(fpsTimestampsSnap.count - 1) / span : 0
            print("│  Current FPS:     \(String(format: "%.1f", fps))")
            print("│  Total Frames:    \(totalFrames)")
            print("│  Dropped Frames:  \(dropped) (\(totalFrames > 0 ? String(format: "%.1f%%", Double(dropped) / Double(totalFrames) * 100) : "0%"))")
            
            if !fpsDurations.isEmpty {
                let avgDt = fpsDurations.reduce(0, +) / Double(fpsDurations.count)
                let maxDt = fpsDurations.max() ?? 0
                let minDt = fpsDurations.min() ?? 0
                
                let sorted = fpsDurations.sorted()
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
                
                print("│  Frame Times:")
                print("│    Average:       \(String(format: "%.1fms", avgDt))")
                print("│    Min/Max:       \(String(format: "%.1f", minDt))ms / \(String(format: "%.1f", maxDt))ms")
                print("│    P50/P95/P99:   \(String(format: "%.1f", p50))ms / \(String(format: "%.1f", p95))ms / \(String(format: "%.1f", p99))ms")
                
                let variance = fpsDurations.reduce(0.0) { $0 + ($1 - avgDt) * ($1 - avgDt) } / Double(fpsDurations.count)
                let jitter = sqrt(variance)
                print("│    Jitter (σ):    \(String(format: "%.2fms", jitter))")
            }
        } else {
            print("│  No frame data yet")
        }
        
        if vizRate > 0 {
            print("│  Audio Callbacks: \(String(format: "%.1f/s", vizRate))")
        }
        print("└──────────────────────────────────────────────────────")
        
        // ── 4. OPERATION BREAKDOWN BY CATEGORY ──
        if !metricsSnapshot.isEmpty {
            print("\n┌─ ⏱️  OPERATIONS BY CATEGORY ──────────────────────────")
            
            for category in Category.allCases {
                let ops = metricsSnapshot.filter { $0.value.category == category }
                guard !ops.isEmpty else { continue }
                
                let totalTime = ops.reduce(0.0) { $0 + $1.value.totalTime }
                let totalCalls = ops.reduce(0) { $0 + $1.value.callCount }
                
                print("│")
                print("│  \(category.rawValue)  (total: \(String(format: "%.1fms", totalTime)), \(totalCalls) calls)")
                
                let sortedOps = ops.sorted { $0.value.recentAverage > $1.value.recentAverage }
                for (label, metric) in sortedOps {
                    let pad = label.padding(toLength: 30, withPad: " ", startingAt: 0)
                    let recent = String(format: "%6.2fms", metric.recentAverage)
                    let allTime = String(format: "%6.2fms", metric.averageTime)
                    let maxStr = String(format: "%6.2fms", metric.maxTime)
                    let calls = "\(metric.callCount)×"
                    print("│    \(pad) recent:\(recent)  avg:\(allTime)  max:\(maxStr)  \(calls)")
                }
            }
            print("└──────────────────────────────────────────────────────")
        }
        
        // ── 5. ENERGY & BATTERY IMPACT ──
        print("\n┌─ 🔋 ENERGY & BATTERY IMPACT ─────────────────────────")
        if energySnapshot.count > 1 {
            let avgWatts = energySnapshot.reduce(0.0) { $0 + $1.estimatedWatts } / Double(energySnapshot.count)
            let peakWatts = energySnapshot.map { $0.estimatedWatts }.max() ?? 0
            
            let avgAmps = avgWatts / 3.8
            let hoursElapsed = elapsed / 3600.0
            let mahDrained = avgAmps * 1000.0 * hoursElapsed
            let projectedHours = avgAmps > 0 ? 3.2 / avgAmps : 99
            
            print("│  Avg Power Draw:    \(String(format: "%.2f W", avgWatts))")
            print("│  Peak Power Draw:   \(String(format: "%.2f W", peakWatts))")
            print("│  Est. Drain (window): \(String(format: "%.2f mAh", mahDrained))")
            print("│  Projected Battery: ~\(String(format: "%.1fh", projectedHours)) total")
            print("│")
            
            let avgCPU = energySnapshot.reduce(0.0) { $0 + $1.cpuUsage } / Double(energySnapshot.count)
            let cpuWatts = avgCPU * 0.005
            let screenWatts = 0.8
            let audioWatts = 0.1
            let baseWatts = 0.3
            let total = cpuWatts + screenWatts + audioWatts + baseWatts
            
            print("│  ⚡ POWER BREAKDOWN:")
            print("│    CPU Processing:  \(String(format: "%.2f W", cpuWatts)) (\(String(format: "%.0f%%", cpuWatts/total*100)))")
            print("│    Display:         \(String(format: "%.2f W", screenWatts)) (\(String(format: "%.0f%%", screenWatts/total*100)))")
            print("│    Audio Engine:    \(String(format: "%.2f W", audioWatts)) (\(String(format: "%.0f%%", audioWatts/total*100)))")
            print("│    System Base:     \(String(format: "%.2f W", baseWatts)) (\(String(format: "%.0f%%", baseWatts/total*100)))")
            
            if let latest = energySnapshot.last {
                let mainCPU = latest.activeThreadCPU.filter { $0.key == "Main" }.values.first ?? 0
                let audioCPU = latest.activeThreadCPU.filter { $0.key.contains("Audio") }.values.reduce(0, +)
                let renderCPU = latest.activeThreadCPU.filter { $0.key.contains("CoreAnimation") || $0.key.contains("Metal") }.values.reduce(0, +)
                let otherCPU = max(0, latest.cpuUsage - mainCPU - audioCPU - renderCPU)
                
                print("│")
                print("│  🧮 CPU BUDGET BREAKDOWN:")
                print("│    Main Thread:     \(String(format: "%5.1f%%", mainCPU)) — SwiftUI layout + state updates")
                print("│    Audio Threads:   \(String(format: "%5.1f%%", audioCPU)) — FFT + beat detection + effects")
                print("│    Render Threads:  \(String(format: "%5.1f%%", renderCPU)) — Canvas + compositing")
                print("│    Other:           \(String(format: "%5.1f%%", otherCPU)) — GCD, networking, system")
            }
        } else {
            print("│  Collecting energy data...")
        }
        print("└──────────────────────────────────────────────────────")
        
        // ── 6. BOTTLENECK DETECTION ──
        print("\n┌─ 🚨 BOTTLENECK ANALYSIS ─────────────────────────────")
        var issues: [(severity: String, message: String)] = []
        
        if fpsTimestampsSnap.count > 1 {
            let span = fpsTimestampsSnap.last! - fpsTimestampsSnap.first!
            let fps = span > 0 ? Double(fpsTimestampsSnap.count - 1) / span : 0
            if fps < 50 {
                issues.append(("🔴", "FPS is \(String(format: "%.0f", fps)) — below 50fps target"))
            } else if fps < 58 {
                issues.append(("🟡", "FPS is \(String(format: "%.0f", fps)) — slightly below 60fps"))
            }
        }
        
        if totalFrames > 0 {
            let dropRate = Double(dropped) / Double(totalFrames) * 100
            if dropRate > 10 {
                issues.append(("🔴", "Dropping \(String(format: "%.0f%%", dropRate)) of frames"))
            } else if dropRate > 3 {
                issues.append(("🟡", "Dropping \(String(format: "%.1f%%", dropRate)) of frames"))
            }
        }
        
        if let latest = energySnapshot.last {
            if latest.cpuUsage > 120 {
                issues.append(("🔴", "CPU at \(String(format: "%.0f%%", latest.cpuUsage)) — heavy battery drain"))
            } else if latest.cpuUsage > 80 {
                issues.append(("🟡", "CPU at \(String(format: "%.0f%%", latest.cpuUsage)) — moderate battery impact"))
            }
            
            let mainCPU = latest.activeThreadCPU["Main"] ?? 0
            if mainCPU > 60 {
                issues.append(("🔴", "Main thread at \(String(format: "%.0f%%", mainCPU)) — UI may stutter"))
            }
        }
        
        for (label, metric) in metricsSnapshot {
            if metric.recentAverage > 16.67 {
                issues.append(("🔴", "\(label): \(String(format: "%.1fms", metric.recentAverage)) avg — blocks frame"))
            } else if metric.recentAverage > 8 {
                issues.append(("🟡", "\(label): \(String(format: "%.1fms", metric.recentAverage)) avg — uses >50% frame budget"))
            }
        }
        
        if !fpsDurations.isEmpty {
            let avgDt = fpsDurations.reduce(0, +) / Double(fpsDurations.count)
            let variance = fpsDurations.reduce(0.0) { $0 + ($1 - avgDt) * ($1 - avgDt) } / Double(fpsDurations.count)
            let jitter = sqrt(variance)
            if jitter > 5.0 {
                issues.append(("🟡", "High frame jitter (\(String(format: "%.1fms", jitter))σ) — inconsistent pacing"))
            }
        }
        
        if issues.isEmpty {
            print("│  ✅ No significant bottlenecks detected")
        } else {
            for issue in issues.sorted(by: { $0.severity < $1.severity }) {
                print("│  \(issue.severity) \(issue.message)")
            }
        }
        print("└──────────────────────────────────────────────────────")
        
        // ── 7. RECOMMENDATIONS ──
        if !issues.isEmpty {
            print("\n┌─ 💡 RECOMMENDATIONS ─────────────────────────────────")
            if let latest = energySnapshot.last {
                let mainCPU = latest.activeThreadCPU["Main"] ?? 0
                let audioCPU = latest.activeThreadCPU.filter { $0.key.contains("Audio") }.values.reduce(0, +)
                let renderCPU = latest.activeThreadCPU.filter { $0.key.contains("CoreAnimation") || $0.key.contains("Metal") }.values.reduce(0, +)
                
                if mainCPU > 40 {
                    print("│  • Main thread busy — reduce @Published updates or extract views")
                }
                if audioCPU > 30 {
                    print("│  • Audio processing heavy — consider reducing FFT size or callback rate")
                }
                if renderCPU > 25 {
                    print("│  • Rendering heavy — reduce bar count, glow effects, or frame rate")
                }
                if latest.cpuUsage > 80 {
                    print("│  • Overall CPU high — consider throttling visualization to 30fps")
                }
            }
            print("└──────────────────────────────────────────────────────")
        }
        
        print(String(repeating: "═", count: 80) + "\n")
    }
    
    // MARK: - On-Demand
    
    func printStatsNow() {
        exportStats()
    }
    
    func reset() {
        lock.lock()
        metrics.removeAll()
        frameTimestamps.removeAll()
        frameDurations.removeAll()
        energyHistory.removeAll()
        vizCallbackTimestamps.removeAll()
        droppedFrameCount = 0
        totalFrameCount = 0
        vizCallbackRate = 0
        lastReportTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        print("🔄 [PerformanceMonitor] All metrics reset")
    }
    
    func getCurrentSystemMetrics() -> (cpu: Double, memory: String, thermal: String, energy: String) {
        let threads = getPerThreadCPU()
        let cpu = threads.reduce(0.0) { $0 + $1.cpuUsage }
        let memory = getMemoryUsage()
        let memoryStr = "\(formatBytes(memory.used)) / \(formatBytes(memory.total))"
        let thermal = thermalStateString(ProcessInfo.processInfo.thermalState)
        
        let cpuW = cpu * 0.005
        let totalW = 0.3 + cpuW + 0.8 + 0.1
        let energy = String(format: "%.2fW", totalW)
        
        return (cpu, memoryStr, thermal, energy)
    }
}