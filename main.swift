import SwiftUI
import Charts
import AppKit
import Metal
import IOKit

// MARK: - System info

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buf)
}

func sysctlInt32(_ name: String) -> Int? {
    var v: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return Int(v)
}

func sysctlUInt64(_ name: String) -> UInt64? {
    var v: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return v
}

let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let machineChip = sysctlString("machdep.cpu.brand_string")
let machineRAMBytes = sysctlUInt64("hw.memsize") ?? 0
let logicalCores = max(1, sysctlInt32("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount)
let performanceCores = sysctlInt32("hw.perflevel0.physicalcpu") ?? 0
let efficiencyCores = sysctlInt32("hw.perflevel1.physicalcpu") ?? 0

/// GPU core count from IORegistry (resolves multi-config official bandwidth); 0 if unavailable
let gpuCoreCount: Int = {
    var iter = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iter) }
    var cores = 0
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any],
           let n = dict["gpu-core-count"] as? Int {
            cores = max(cores, n)
        }
        IOObjectRelease(svc)
    }
    return cores
}()

var coreSummary: String {
    if performanceCores > 0, efficiencyCores > 0 {
        return "\(performanceCores)P+\(efficiencyCores)E · \(logicalCores) threads"
    }
    return "\(logicalCores) threads"
}

func formatGB(_ bytes: UInt64) -> String {
    // Binary units: 17179869184 bytes = 16 GiB (what Apple labels as 16 GB)
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.0f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}


// MARK: - Apple official memory bandwidth specs (reference)

struct ChipSpec: Identifiable {
    let label: String                    // chip family
    let lowText: String                  // standard-config official bandwidth (e.g. "460")
    var highText: String? = nil          // high-end config bandwidth (e.g. "614")
    var gpuHighThreshold: Int? = nil     // GPU cores >= this value -> high-config bandwidth
    var ramHighThresholdGB: Int? = nil   // RAM >= this value -> high-config bandwidth
    var id: String { label }

    /// nil = detection unavailable (fall back to showing both numbers)
    private var isHigh: Bool? {
        guard highText != nil else { return false }
        if let t = gpuHighThreshold {
            guard gpuCoreCount > 0 else { return nil }
            return gpuCoreCount >= t
        }
        if let t = ramHighThresholdGB {
            return Int(machineRAMBytes / 1_073_741_824) >= t
        }
        return false
    }

    var officialDisplay: String {
        let sep = "/"
        guard let high = highText else { return lowText + " GB/s" }
        switch isHigh {
        case .some(true):
            let note = gpuHighThreshold != nil
                ? "(\(gpuCoreCount)-core GPU)"
                : "(by RAM capacity)"
            return high + " GB/s " + note
        case .some(false):
            return lowText + " GB/s"
        case nil:
            return lowText + sep + high + " GB/s " + "(by GPU config)"
        }
    }

    var baselineGBps: Double {
        (isHigh ?? false) ? (Double(highText ?? "") ?? 0) : (Double(lowText) ?? 0)
    }
}

/// Numbers taken from Apple's official tech-spec pages; bandwidth varies by configuration within a family.
let appleChipSpecs: [ChipSpec] = [
    ChipSpec(label: "M1", lowText: "68.25"),
    ChipSpec(label: "M1 Pro", lowText: "200"),
    ChipSpec(label: "M1 Max", lowText: "400"),
    ChipSpec(label: "M1 Ultra", lowText: "800"),
    ChipSpec(label: "M2", lowText: "100"),
    ChipSpec(label: "M2 Pro", lowText: "200"),
    ChipSpec(label: "M2 Max", lowText: "400"),
    ChipSpec(label: "M2 Ultra", lowText: "800"),
    ChipSpec(label: "M3", lowText: "100"),
    ChipSpec(label: "M3 Pro", lowText: "150"),
    ChipSpec(label: "M3 Max", lowText: "300", highText: "400", gpuHighThreshold: 40),
    ChipSpec(label: "M4", lowText: "120"),
    ChipSpec(label: "M4 Pro", lowText: "273"),
    ChipSpec(label: "M4 Max", lowText: "410", highText: "546", gpuHighThreshold: 40),
    ChipSpec(label: "M5", lowText: "153", highText: "170", ramHighThresholdGB: 24),
    ChipSpec(label: "M5 Pro", lowText: "307"),
    ChipSpec(label: "M5 Max", lowText: "460", highText: "614", gpuHighThreshold: 40),
]

/// Match the chip family from brand_string; longest label first so "M5 Max" is not matched by "M5".
let currentChipSpec: ChipSpec? = {
    let chip = machineChip
    return appleChipSpecs
        .sorted { $0.label.count > $1.label.count }
        .first { chip.localizedCaseInsensitiveContains($0.label) }
}()
// MARK: - Monotonic clock and anti-optimization

@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always) func nsToSec(_ ns: UInt64) -> Double { Double(ns) / 1_000_000_000 }

/// Single-threaded paths only; multi-threaded code writes its own buffer
var globalSink: UInt64 = 0
@inline(never) func blackHole(_ x: UInt64) { globalSink = x }

final class StopFlag {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock(); flag = true; lock.unlock()
    }
}

// MARK: - Test model

enum TestMode: String, CaseIterable, Identifiable {
    case read = "read"
    case write = "write"
    case writePingPong = "write-pingpong"
    case copy = "copy"
    case cpuGpu = "cpu+gpu"
    case gpuOnly = "gpu-only"
    var id: String { rawValue }   // stable English key (CSV / debugging)

    var display: String {
        switch self {
        case .read:  return "Read"
        case .write: return "Write"
        case .writePingPong: return "Write (ping-pong)"
        case .copy:  return "Copy"
        case .cpuGpu: return "CPU+GPU concurrent"
        case .gpuOnly: return "GPU-only"
        }
    }

    var detail: String {
        switch self {
        case .read:  return "Each thread scans its own buffer sequentially (8-way unrolled uint64 accumulation to raise outstanding requests)"
        case .write: return "Each thread fills its own buffer (8-way unrolled stores)"
        case .writePingPong: return "Alternates two buffers each iteration so the previous round's dirty lines must be evicted this round, closer to sustained DRAM write bandwidth"
        case .copy:  return "memcpy src to dst; traffic counts both read and write bytes"
        case .cpuGpu: return "All CPU threads scan while a Metal kernel reads concurrently; the total is closest to the SoC's real DRAM ceiling"
        case .gpuOnly: return "GPU reads at full throttle with pipelined command buffers keeping the queue saturated; no CPU traffic, measures what the GPU alone can pull"
        }
    }

    /// SF Symbol shown next to the mode in the UI.
    var symbol: String {
        switch self {
        case .read:  return "arrow.down.to.line"
        case .write: return "square.and.pencil"
        case .writePingPong: return "arrow.left.arrow.right"
        case .copy:  return "doc.on.doc"
        case .cpuGpu: return "circle.grid.cross.fill"
        case .gpuOnly: return "cube.transparent"
        }
    }

    /// Compact label used on the chart axis.
    var shortDisplay: String {
        switch self {
        case .read:  return "Read"
        case .write: return "Write"
        case .writePingPong: return "Ping-pong"
        case .copy:  return "Copy"
        case .cpuGpu: return "CPU+GPU"
        case .gpuOnly: return "GPU"
        }
    }

    /// One-line summary shown under the mode name in the sidebar.
    var blurb: String {
        switch self {
        case .read:  return "Sequential reads, 8-way unrolled"
        case .write: return "Sequential writes to the buffer"
        case .writePingPong: return "Alternating buffers, sustained write traffic"
        case .copy:  return "memcpy; counts both read and write bytes"
        case .cpuGpu: return "CPU threads and a Metal kernel at once"
        case .gpuOnly: return "Metal only, pipelined command buffers"
        }
    }
}

struct BenchResult: Identifiable {
    let id = UUID()
    let mode: TestMode
    let avgGBps: Double
    let peakGBps: Double
    let avgMs: Double
    var cpuGBps: Double? = nil   // meaningful only in CPU+GPU concurrent mode
    var gpuGBps: Double? = nil
}

// MARK: - Test engine

final class Runner: ObservableObject {
    struct RunSnapshot {
        let sizeMB: Int
        let threads: Int
        let iterations: Int
        let startedAt: Date
    }

    @Published var running = false
    @Published var results: [BenchResult] = []
    @Published var progressDone = 0
    @Published var progressTotal = 1
    @Published var statusText = "Ready to benchmark"
    @Published var errorMessage: String?
    @Published private(set) var lastRun: RunSnapshot?

    private let stateLock = NSLock()
    private var cancelRequested = false

    // MARK: Metal (initialized on first use of CPU+GPU mode)
    private let mtlDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var mtlQueue: MTLCommandQueue?
    private var gpuPso: MTLComputePipelineState?
    private var gpuBuf: MTLBuffer?
    private var gpuOutBuf: MTLBuffer?
    private let gpuThreads = 32768
    private var activityToken: NSObjectProtocol?

    static let gpuKernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void bw_read(device const float4* buf [[buffer(0)]],
                        device float4* out [[buffer(1)]],
                        constant uint& count [[buffer(2)]],
                        uint tid [[thread_position_in_grid]],
                        uint total [[threads_per_grid]]) {
        float4 acc = float4(0.0);
        for (uint i = tid; i < count; i += total) { acc += buf[i]; }
        out[tid] = acc;
    }
    """

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelRequested
    }

    func cancel() {
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
        statusText = "Stopping…"
    }

    // MARK: Run flow

    func run(sizeMB: Int, threads: Int, iterations: Int, modes: [TestMode]) {
        guard !running else { return }
        stateLock.lock(); cancelRequested = false; stateLock.unlock()

        running = true
        results = []
        errorMessage = nil
        progressTotal = max(1, modes.reduce(0) { $0 + (($1 == .cpuGpu || $1 == .gpuOnly) ? iterations * 8 : iterations) })
        progressDone = 0
        statusText = "Allocating memory…"
        lastRun = RunSnapshot(sizeMB: sizeMB, threads: threads, iterations: iterations, startedAt: Date())
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Memory bandwidth benchmark running")

        // userInteractive: keep test threads off E-cores, which would depress read bandwidth
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer { self.finishRun() }

            let bytes = sizeMB * 1024 * 1024
            var rawSrc: UnsafeMutableRawPointer?
            var rawDst: UnsafeMutableRawPointer?
            let r1 = posix_memalign(&rawSrc, 4096, bytes)
            let r2 = posix_memalign(&rawDst, 4096, bytes)
            guard r1 == 0, r2 == 0, let srcRaw = rawSrc, let dstRaw = rawDst else {
                if let p = rawSrc { free(p) }
                if let p = rawDst { free(p) }
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to allocate \(sizeMB) MB x2 test buffers. Please choose a smaller size."
                }
                return
            }
            defer { free(srcRaw); free(dstRaw) }

            // First touch forces real page allocation; not included in timing
            DispatchQueue.main.async { self.statusText = "Warming up…" }
            memset(srcRaw, 0xAB, bytes)
            memset(dstRaw, 0xCD, bytes)

            let src = srcRaw.assumingMemoryBound(to: UInt64.self)
            let dst = dstRaw.assumingMemoryBound(to: UInt64.self)
            let words = bytes / MemoryLayout<UInt64>.size

            for mode in modes where mode != .cpuGpu && mode != .gpuOnly {
                if self.isCancelled { break }
                self.runCPUMode(mode: mode, src: src, dst: dst, bytes: bytes,
                                words: words, threads: threads, iterations: iterations)
            }

            if modes.contains(.cpuGpu), !self.isCancelled {
                self.runCPUPlusGPU(src: src, words: words, bytes: bytes,
                                   threads: threads, iterations: iterations)
            }

            if modes.contains(.gpuOnly), !self.isCancelled {
                self.runGPUOnly(bytes: bytes, iterations: iterations)
            }
        }
    }

    private func runCPUMode(mode: TestMode, src: UnsafeMutablePointer<UInt64>,
                            dst: UnsafeMutablePointer<UInt64>, bytes: Int, words: Int,
                            threads: Int, iterations: Int) {
        // Warm-up pass (untimed): let CPU clocks and TLB/pages settle.
        // Ping-pong warm-up writes src so iteration 1 (writing dst) alternates immediately.
        _ = Runner.measure(mode: mode, src: src, dst: dst, words: words, threads: threads, alt: true)

        var gbps: [Double] = []
        var msList: [Double] = []
        for it in 1...iterations {
            if isCancelled { break }
            let index = it
            DispatchQueue.main.async { self.statusText = "\(mode.display): pass \(index)/\(iterations)…" }
            let secs = Runner.measure(mode: mode, src: src, dst: dst, words: words,
                                      threads: threads, alt: it % 2 == 0)
            let moved = mode == .copy ? Double(bytes) * 2 : Double(bytes)
            gbps.append(moved / secs / 1_000_000_000)
            msList.append(secs * 1000)
            DispatchQueue.main.async { self.progressDone += 1 }
        }
        guard !gbps.isEmpty else { return }
        let avg = gbps.reduce(0, +) / Double(gbps.count)
        let peak = gbps.max() ?? 0
        let avgMs = msList.reduce(0, +) / Double(msList.count)
        DispatchQueue.main.async {
            self.results.append(BenchResult(mode: mode, avgGBps: avg, peakGBps: peak, avgMs: avgMs))
        }
    }

    private func runCPUPlusGPU(src: UnsafeMutablePointer<UInt64>, words: Int, bytes: Int,
                               threads: Int, iterations: Int) {
        guard setupGPUBuffers(bytes: bytes) else {
            DispatchQueue.main.async {
                self.errorMessage = "Metal initialization or GPU buffer allocation failed; the CPU+GPU concurrent test was skipped."
                self.progressDone += iterations * 8
            }
            return
        }
        _ = measureCPUGPU(src: src, words: words, threads: threads)   // warm-up

        var totals: [Double] = []
        var cpuPart: [Double] = []
        var gpuPart: [Double] = []
        var msList: [Double] = []
        for it in 1...iterations {
            if isCancelled { break }
            let index = it
            DispatchQueue.main.async { self.statusText = "\(TestMode.cpuGpu.display): pass \(index)/\(iterations)…" }
            let r = measureCPUGPU(src: src, words: words, threads: threads)
            totals.append(r.total); cpuPart.append(r.cpu); gpuPart.append(r.gpu)
            msList.append(r.secs * 1000)
            DispatchQueue.main.async { self.progressDone += 8 }
        }
        guard !totals.isEmpty else { return }
        let avg = totals.reduce(0, +) / Double(totals.count)
        let peak = totals.max() ?? 0
        let avgMs = msList.reduce(0, +) / Double(msList.count)
        let cAvg = cpuPart.reduce(0, +) / Double(cpuPart.count)
        let gAvg = gpuPart.reduce(0, +) / Double(gpuPart.count)
        DispatchQueue.main.async {
            self.results.append(BenchResult(mode: .cpuGpu, avgGBps: avg, peakGBps: peak,
                                            avgMs: avgMs, cpuGBps: cAvg, gpuGBps: gAvg))
        }
    }

    private func runGPUOnly(bytes: Int, iterations: Int) {
        guard setupGPUBuffers(bytes: bytes) else {
            DispatchQueue.main.async {
                self.errorMessage = "Metal initialization or GPU buffer allocation failed; the GPU-only test was skipped."
                self.progressDone += iterations * 8
            }
            return
        }
        _ = measureGPUOnly(windowSecs: 0.25)   // warm-up

        var gbps: [Double] = []
        for it in 1...iterations {
            if isCancelled { break }
            let index = it
            DispatchQueue.main.async { self.statusText = "\(TestMode.gpuOnly.display): pass \(index)/\(iterations)…" }
            guard let g = measureGPUOnly() else { break }
            gbps.append(g)
            DispatchQueue.main.async { self.progressDone += 8 }
        }
        guard !gbps.isEmpty else { return }
        let avg = gbps.reduce(0, +) / Double(gbps.count)
        let peak = gbps.max() ?? 0
        DispatchQueue.main.async {
            self.results.append(BenchResult(mode: .gpuOnly, avgGBps: avg, peakGBps: peak, avgMs: 500))
        }
    }

    /// GPU-only full-throttle reads: several command buffers stay in flight so the GPU
    /// queue never drains between bursts; no CPU traffic competes for the bus.
    private func measureGPUOnly(windowSecs: Double = 0.5) -> Double? {
        guard let queue = mtlQueue, let pso = gpuPso,
              let buf = gpuBuf, let out = gpuOutBuf else { return nil }
        var count = UInt32(buf.length / 16)   // float4 = 16 bytes
        let passesPerBurst = 8
        let inflightLimit = 4
        let bytesPerBurst = Double(buf.length) * Double(passesPerBurst)
        func commitBurst() -> MTLCommandBuffer? {
            guard let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(pso)
            enc.setBuffer(buf, offset: 0, index: 0)
            enc.setBuffer(out, offset: 0, index: 1)
            enc.setBytes(&count, length: 4, index: 2)
            for _ in 0..<passesPerBurst {
                enc.dispatchThreads(MTLSize(width: gpuThreads, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            enc.endEncoding()
            cb.commit()
            return cb
        }
        var totalBytes = 0.0
        var ring: [MTLCommandBuffer] = []
        let t0 = nowNs()
        while nsToSec(nowNs() - t0) < windowSecs {
            guard let cb = commitBurst() else { break }
            ring.append(cb)
            totalBytes += bytesPerBurst
            if ring.count >= inflightLimit {
                ring.removeFirst().waitUntilCompleted()
            }
        }
        for cb in ring { cb.waitUntilCompleted() }
        let win = max(nsToSec(nowNs() - t0), 0.001)
        return totalBytes / win / 1e9
    }

    /// Single exit path: guarantees the power assertion is released (alloc failure, cancel, etc.)
    private func finishRun() {
        let cancelled = isCancelled
        DispatchQueue.main.async {
            if let token = self.activityToken {
                ProcessInfo.processInfo.endActivity(token)
                self.activityToken = nil
            }
            self.running = false
            self.statusText = cancelled ? "Stopped" : "Done"
        }
    }

    // MARK: Measurement

    /// Returns seconds. Runs shorter than 20 ms repeat automatically to amortize thread-wakeup jitter.
    static func measure(mode: TestMode, src: UnsafeMutablePointer<UInt64>,
                        dst: UnsafeMutablePointer<UInt64>, words: Int, threads: Int,
                        alt: Bool) -> Double {
        let first = measureOnce(mode: mode, src: src, dst: dst, words: words,
                                threads: threads, alt: alt)
        let minWindow = 0.02
        guard first < minWindow else { return first }
        let reps = min(64, max(2, Int(minWindow / max(first, 1e-6)) + 1))
        let t0 = nowNs()
        for _ in 0..<reps {
            _ = measureOnce(mode: mode, src: src, dst: dst, words: words,
                            threads: threads, alt: alt)
        }
        // Returns the per-pass average so callers do not count repeats as extra traffic
        return nsToSec(nowNs() - t0) / Double(reps)
    }

    private static func measureOnce(mode: TestMode, src: UnsafeMutablePointer<UInt64>,
                                    dst: UnsafeMutablePointer<UInt64>, words: Int,
                                    threads: Int, alt: Bool) -> Double {
        let chunk = max(64, (words / threads) & ~63)   // align to 512 bytes
        let t0 = nowNs()
        switch mode {
        case .cpuGpu, .gpuOnly:
            return 0   // cpuGpu/gpuOnly use their own paths; unreachable here
        case .read:
            var sums = [UInt64](repeating: 0, count: threads)
            DispatchQueue.concurrentPerform(iterations: threads) { i in
                let start = i * chunk
                let end = (i == threads - 1) ? words : min(start + chunk, words)
                guard end > start else { return }
                sums[i] = readRun(src + start, end - start)
            }
            blackHole(sums.reduce(0, &+))
        case .write:
            DispatchQueue.concurrentPerform(iterations: threads) { i in
                let start = i * chunk
                let end = (i == threads - 1) ? words : min(start + chunk, words)
                guard end > start else { return }
                writeRun(dst + start, end - start)
            }
            blackHole(dst[0])
        case .writePingPong:
            let target = alt ? src : dst
            DispatchQueue.concurrentPerform(iterations: threads) { i in
                let start = i * chunk
                let end = (i == threads - 1) ? words : min(start + chunk, words)
                guard end > start else { return }
                writeRun(target + start, end - start)
            }
            blackHole(target[0])
        case .copy:
            DispatchQueue.concurrentPerform(iterations: threads) { i in
                let start = i * chunk
                let end = (i == threads - 1) ? words : min(start + chunk, words)
                guard end > start else { return }
                memcpy(dst + start, src + start, (end - start) * MemoryLayout<UInt64>.size)
            }
            blackHole(dst[0])
        }
        return nsToSec(nowNs() - t0)
    }

    @inline(never)
    static func readRun(_ p: UnsafeMutablePointer<UInt64>, _ n: Int) -> UInt64 {
        // 8-way unroll: raise outstanding read requests per core
        var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0, d: UInt64 = 0
        var e: UInt64 = 0, f: UInt64 = 0, g: UInt64 = 0, h: UInt64 = 0
        var i = 0
        let limit = n - (n % 8)
        while i < limit {
            a &+= p[i];     b &+= p[i + 1]; c &+= p[i + 2]; d &+= p[i + 3]
            e &+= p[i + 4]; f &+= p[i + 5]; g &+= p[i + 6]; h &+= p[i + 7]
            i += 8
        }
        while i < n { a &+= p[i]; i += 1 }
        return (a &+ b) &+ (c &+ d) &+ (e &+ f) &+ (g &+ h)
    }

    @inline(never)
    static func writeRun(_ p: UnsafeMutablePointer<UInt64>, _ n: Int) {
        let pattern: UInt64 = 0x0123456789ABCDEF
        var i = 0
        let limit = n - (n % 8)
        while i < limit {
            p[i] = pattern; p[i + 1] = pattern; p[i + 2] = pattern; p[i + 3] = pattern
            p[i + 4] = pattern; p[i + 5] = pattern; p[i + 6] = pattern; p[i + 7] = pattern
            i += 8
        }
        while i < n { p[i] = pattern; i += 1 }
    }

    // MARK: Metal

    private func prepareMetal() -> Bool {
        if gpuPso != nil, mtlQueue != nil { return true }
        guard let device = mtlDevice,
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.gpuKernelSource, options: nil),
              let fn = lib.makeFunction(name: "bw_read"),
              let pso = try? device.makeComputePipelineState(function: fn) else { return false }
        mtlQueue = queue
        gpuPso = pso
        return true
    }

    /// Allocate GPU buffers; private storage must be pre-filled to avoid reading uninitialized memory.
    private func setupGPUBuffers(bytes: Int) -> Bool {
        guard prepareMetal(), let device = mtlDevice, let queue = mtlQueue else { return false }
        let gpuBytes = min(bytes, 256 * 1024 * 1024)
        if let existing = gpuBuf, Int(existing.length) == gpuBytes, gpuOutBuf != nil { return true }

        guard let buf = device.makeBuffer(length: gpuBytes, options: .storageModePrivate),
              let out = device.makeBuffer(length: gpuThreads * 16, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return false }
        blit.__fill(buf, range: NSRange(location: 0, length: gpuBytes), value: 0)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        gpuBuf = buf
        gpuOutBuf = out
        return true
    }

    /// Batch multiple GPU read passes into one command buffer to cut per-pass submit/wait overhead.
    private func gpuBurst(passes: Int) -> Double? {
        guard let queue = mtlQueue, let pso = gpuPso,
              let buf = gpuBuf, let out = gpuOutBuf,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        var count = UInt32(buf.length / 16)   // float4 = 16 bytes
        enc.setComputePipelineState(pso)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBuffer(out, offset: 0, index: 1)
        enc.setBytes(&count, length: 4, index: 2)
        for _ in 0..<passes {
            enc.dispatchThreads(MTLSize(width: gpuThreads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Double(buf.length) * Double(passes)
    }

    /// All CPU threads scan within the timed window while the GPU reads back-to-back.
    func measureCPUGPU(src: UnsafeMutablePointer<UInt64>, words: Int, threads: Int)
        -> (total: Double, cpu: Double, gpu: Double, secs: Double) {
        let chunk = max(64, (words / threads) & ~63)
        let perThread = UnsafeMutablePointer<Double>.allocate(capacity: threads)
        perThread.initialize(repeating: 0, count: threads)
        let sinkOut = UnsafeMutablePointer<UInt64>.allocate(capacity: threads)
        sinkOut.initialize(repeating: 0, count: threads)
        defer {
            perThread.deinitialize(count: threads); perThread.deallocate()
            sinkOut.deinitialize(count: threads); sinkOut.deallocate()
        }

        let stop = StopFlag()
        let group = DispatchGroup()
        for t in 0..<threads {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                var acc: UInt64 = 0
                var n = 0
                let t0 = nowNs()   // each thread times from when it actually starts
                while !stop.value {
                    acc &+= Runner.readRun(src + t * chunk, chunk)
                    n += 1
                }
                let el = max(nsToSec(nowNs() - t0), 0.001)
                perThread[t] = Double(n) * Double(chunk * 8) / el / 1e9
                sinkOut[t] = acc
                group.leave()
            }
        }

        // GPU runs back-to-back inside a fixed 0.5 s window, then ends the round
        let windowSecs = 0.5
        let passesPerBurst = 4
        let wStart = nowNs()
        var gpuBytes = 0.0
        while nsToSec(nowNs() - wStart) < windowSecs {
            guard let moved = gpuBurst(passes: passesPerBurst) else { break }
            gpuBytes += moved
        }
        let win = max(nsToSec(nowNs() - wStart), 0.001)
        stop.set()
        group.wait()

        // per-thread timings summed (late-scheduled threads do not dilute the result)
        let cpuGBps = (0..<threads).reduce(0.0) { $0 + perThread[$1] }
        blackHole((0..<threads).reduce(UInt64(0)) { $0 &+ sinkOut[$1] })
        let gpuGBps = gpuBytes / win / 1e9
        return (cpuGBps + gpuGBps, cpuGBps, gpuGBps, win)
    }
}
extension Runner {
    /// --self-test fast path: one small pass per mode, JSON to stdout (for CI).
    func selfTest(sizeMB: Int = 16, threads: Int = 2) -> [String] {
        let bytes = sizeMB * 1024 * 1024
        var rawSrc: UnsafeMutableRawPointer?
        var rawDst: UnsafeMutableRawPointer?
        guard posix_memalign(&rawSrc, 4096, bytes) == 0,
              posix_memalign(&rawDst, 4096, bytes) == 0,
              let srcRaw = rawSrc, let dstRaw = rawDst else { return [] }
        defer { free(srcRaw); free(dstRaw) }
        memset(srcRaw, 0xAB, bytes)
        memset(dstRaw, 0xCD, bytes)
        let src = srcRaw.assumingMemoryBound(to: UInt64.self)
        let dst = dstRaw.assumingMemoryBound(to: UInt64.self)
        let words = bytes / MemoryLayout<UInt64>.size
        var lines: [String] = []
        for mode in [TestMode.read, .write, .writePingPong, .copy] {
            let secs = Runner.measure(mode: mode, src: src, dst: dst, words: words,
                                      threads: threads, alt: false)
            let moved = mode == .copy ? Double(bytes) * 2 : Double(bytes)
            lines.append("{\"mode\":\"\(mode.rawValue)\",\"gbps\":\(String(format: "%.2f", moved / max(secs, 1e-9) / 1e9)),\"ms\":\(String(format: "%.2f", secs * 1000))}")
        }
        if setupGPUBuffers(bytes: bytes) {
            let r = measureCPUGPU(src: src, words: words, threads: threads)
            lines.append("{\"mode\":\"cpu+gpu\",\"gbps\":\(String(format: "%.2f", r.total))}")
            if let g = measureGPUOnly(windowSecs: 0.25) {
                lines.append("{\"mode\":\"gpu-only\",\"gbps\":\(String(format: "%.2f", g))}")
            }
        }
        return lines
    }
}

// MARK: - Visual design

enum Palette {
    /// Accent used for primary actions and measured throughput.
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.00)      // #0A84FF
    static let accentDeep = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    /// Marks a result that reaches a realistic share of the official spec.
    static let good = Color(red: 0.06, green: 0.72, blue: 0.51)         // #10B981
    /// Apple's orange, reserved for the official-spec reference.
    static let official = Color(red: 1.00, green: 0.58, blue: 0.00)      // #FF9500

    static let barGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .top, endPoint: .bottom)
}

extension View {
    /// Rounded panel treatment shared by every card in the window.
    func panelStyle(cornerRadius: CGFloat = 14) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var sizeMB: Int = 256
    @State private var threads: Int = logicalCores
    @State private var iterations: Int = 5
    @State private var selectedModes: Set<TestMode> = Set(TestMode.allCases)

    /// Only sizes this machine can hold (two buffers <= half of physical RAM)
    private var sizeOptions: [Int] {
        let options = [16, 64, 256, 1024]
        let usable = machineRAMBytes / 2
        let filtered = options.filter { UInt64($0) * 1024 * 1024 * 2 <= usable }
        return filtered.isEmpty ? [16] : filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 340)
                Divider()
                resultsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1060, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text("Memory Bandwidth Bench")
                    .font(.system(size: 14, weight: .semibold))
                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            infoPill(icon: "cpu", text: machineChip)
            infoPill(icon: "memorychip", text: "\(formatGB(machineRAMBytes)) · \(coreSummary)")
            if let spec = currentChipSpec {
                officialPill(spec)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .foregroundStyle(.secondary)
    }

    private func officialPill(_ spec: ChipSpec) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.official).frame(width: 6, height: 6)
            Text("Official \(spec.officialDisplay)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Palette.official.opacity(0.13), in: .capsule)
        .foregroundStyle(Palette.official)
        .help("Apple's published memory bandwidth for this chip. It is the theoretical LPDDR bus peak, so measured results normally land at 50-80% of it.")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    configPanel
                    modesPanel
                }
                .padding(13)
            }
            Divider()
            actionBar
        }
        .frame(maxHeight: .infinity)
    }

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            panelHeader("Configuration", icon: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Buffer size")
                Picker("", selection: $sizeMB) {
                    ForEach(sizeOptions, id: \.self) { Text(sizeLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(runner.running)
                .help("Small buffers (16/64 MB) are absorbed by the cache and read far above real DRAM bandwidth. Use 256 MB or more to measure DRAM.")
            }

            stepperRow(title: "Threads", unit: "threads",
                       value: $threads, range: 1...max(1, logicalCores),
                       hint: "CPU threads used by the CPU-side tests. Every logical core is the usual choice.")
            stepperRow(title: "Iterations", unit: "passes",
                       value: $iterations, range: 1...20,
                       hint: "How many times each test repeats. The average across all passes is reported.")
        }
        .padding(13)
        .panelStyle()
    }

    private var modesPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                panelHeader("Test modes", icon: "checklist")
                Spacer()
                Text("\(selectedModes.count) of \(TestMode.allCases.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(TestMode.allCases) { mode in
                    modeRow(mode)
                }
            }
        }
        .padding(13)
        .panelStyle()
    }

    private func modeRow(_ mode: TestMode) -> some View {
        let on = selectedModes.contains(mode)
        return Toggle(isOn: binding(for: mode)) {
            HStack(spacing: 9) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Palette.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.display)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(mode.blurb)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(runner.running)
        .padding(.vertical, 3)
        .help(mode.detail)
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let err = runner.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text(runner.running ? "Running…" : "Run Benchmark")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.running || selectedModes.isEmpty)

                Button {
                    runner.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!runner.running)
                .help("Stop the running benchmark")
            }

            HStack(spacing: 8) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .disabled(runner.results.isEmpty)
                Spacer()
                if runner.progressTotal > 1 {
                    Text("\(min(runner.progressDone, runner.progressTotal)) / \(runner.progressTotal)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if runner.running || runner.progressDone > 0 {
                ProgressView(value: Double(min(runner.progressDone, runner.progressTotal)),
                             total: Double(runner.progressTotal))
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
            }

            Text(runner.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
    }

    // MARK: Small building blocks

    private func panelHeader(_ title: String, icon: String) -> some View {
        Label {
            Text(title).font(.system(size: 12, weight: .semibold))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func stepperRow(title: String, unit: String, value: Binding<Int>,
                            range: ClosedRange<Int>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(title)
            Stepper(value: value, in: range) {
                HStack(spacing: 4) {
                    Text("\(value.wrappedValue)")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .disabled(runner.running)
        }
        .help(hint)
    }

    private func sizeLabel(_ mb: Int) -> String {
        mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    private func start() {
        let modes = TestMode.allCases.filter { selectedModes.contains($0) }
        guard !modes.isEmpty else {
            runner.errorMessage = "Please select at least one test."
            return
        }
        runner.errorMessage = nil
        runner.run(sizeMB: sizeMB, threads: threads, iterations: iterations, modes: modes)
    }

    private func binding(for mode: TestMode) -> Binding<Bool> {
        Binding(
            get: { selectedModes.contains(mode) },
            set: { on in
                if on { selectedModes.insert(mode) } else { selectedModes.remove(mode) }
            }
        )
    }

    @ViewBuilder
    private var resultsArea: some View {
        if runner.results.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headlineCard
                    chartCard
                    tableCard
                }
                .padding(13)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speedometer")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Palette.accent.gradient)
            Text(runner.running ? "Benchmark running" : "No measurement yet")
                .font(.title3.weight(.semibold))
            Text(emptyStateHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateHint: String {
        var text = "Pick a buffer size, tick the tests you want, then press Run Benchmark."
        if let spec = currentChipSpec {
            text += " Results are compared against the \(spec.officialDisplay) figure Apple publishes for this chip."
        }
        return text
    }

    private var headlineCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("BEST RESULT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.1f", bestResult?.avgGBps ?? 0))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent.gradient)
                    Text("GB/s")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let best = bestResult {
                    Label {
                        Text(best.mode.display)
                    } icon: {
                        Image(systemName: best.mode.symbol)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, alignment: .leading)

            Divider().frame(height: 56)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Share of the official spec")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", bestRatio * 100))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(bestRatio >= 0.75 ? Palette.good : Color.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Palette.barGradient)
                            .frame(width: max(3, geo.size.width * min(bestRatio, 1)))
                    }
                }
                .frame(height: 9)
                HStack {
                    Text("0")
                    Spacer()
                    Text("\(officialGBpsLabel) official")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .panelStyle()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                panelHeader("Throughput by test", icon: "chart.bar.fill")
                Spacer()
                if currentChipSpec != nil {
                    HStack(spacing: 6) {
                        Capsule().fill(Palette.official).frame(width: 16, height: 2)
                        Text("\(officialGBpsLabel) official")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Chart {
                ForEach(runner.results) { r in
                    BarMark(
                        x: .value("Test", r.mode.shortDisplay),
                        y: .value("GB/s", r.avgGBps),
                        width: .fixed(30)
                    )
                    .foregroundStyle(Palette.barGradient)
                    .cornerRadius(6)
                    .annotation(position: .top, spacing: 3) {
                        Text(String(format: "%.1f", r.avgGBps))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let spec = currentChipSpec {
                    RuleMark(y: .value("Official spec", spec.baselineGBps))
                        .foregroundStyle(Palette.official)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .chartYAxisLabel("GB/s")
            .chartYScale(domain: 0...chartDomainMax)
            .chartXAxis {
                AxisMarks(preset: .aligned, position: .bottom) { value in
                    AxisValueLabel {
                        if let name = value.as(String.self) {
                            Text(name)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color.primary.opacity(0.035))
            }
            .frame(height: 220)
        }
        .padding(16)
        .panelStyle()
    }

    private var tableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("Detailed results", icon: "tablecells")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    tableHeader("Test", width: 158, alignment: .leading)
                    tableHeader("Avg GB/s", width: 70, alignment: .trailing)
                    tableHeader("Peak GB/s", width: 70, alignment: .trailing)
                    tableHeader("% of official", width: 108, alignment: .trailing)
                    tableHeader("Time ms", width: 62, alignment: .trailing)
                    tableHeader("CPU / GPU split", width: 122, alignment: .trailing)
                }
                .padding(.bottom, 7)

                ForEach(Array(runner.results.enumerated()), id: \.element.id) { index, r in
                    if index > 0 { Divider() }
                    resultRow(r)
                }
            }
        }
        .padding(16)
        .panelStyle()
    }

    private func resultRow(_ r: BenchResult) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(r.mode.display).lineLimit(1)
            } icon: {
                Image(systemName: r.mode.symbol).foregroundStyle(Palette.accent)
            }
            .frame(width: 158, alignment: .leading)

            Text(String(format: "%.1f", r.avgGBps))
                .frame(width: 70, alignment: .trailing)
            Text(String(format: "%.1f", r.peakGBps))
                .frame(width: 70, alignment: .trailing)
            percentCell(r)
                .frame(width: 108, alignment: .trailing)
            Text(String(format: "%.1f", r.avgMs))
                .frame(width: 62, alignment: .trailing)
            Text(breakdownText(r))
                .foregroundStyle(r.cpuGBps == nil ? Color.secondary.opacity(0.55) : Color.secondary)
                .frame(width: 122, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.vertical, 8)
    }

    private func percentCell(_ r: BenchResult) -> some View {
        let ratio = officialRatio(r)
        let tint: Color = ratio >= 0.75 ? Palette.good : Palette.accent
        return HStack(spacing: 8) {
            Text(String(format: "%.0f%%", ratio * 100))
                .foregroundStyle(ratio >= 0.75 ? Palette.good : Color.secondary)
                .frame(width: 36, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 60, height: 6)
                Capsule().fill(tint).frame(width: max(2, 60 * min(ratio, 1)), height: 6)
            }
            .frame(width: 60, height: 6)
        }
    }

    private func tableHeader(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func breakdownText(_ r: BenchResult) -> String {
        if let c = r.cpuGBps, let g = r.gpuGBps {
            return String(format: "CPU %.1f + GPU %.1f", c, g)
        }
        return "—"
    }

    private var bestResult: BenchResult? {
        runner.results.max { $0.avgGBps < $1.avgGBps }
    }

    private func officialRatio(_ r: BenchResult) -> Double {
        guard let spec = currentChipSpec, spec.baselineGBps > 0 else { return 0 }
        return r.avgGBps / spec.baselineGBps
    }

    private var bestRatio: Double {
        guard let best = bestResult else { return 0 }
        return officialRatio(best)
    }

    private var officialGBpsLabel: String {
        guard let spec = currentChipSpec else { return "—" }
        return String(format: "%.0f GB/s", spec.baselineGBps)
    }

    private var chartDomainMax: Double {
        let measured = runner.results.map { $0.avgGBps }.max() ?? 1
        let official = currentChipSpec?.baselineGBps ?? 0
        return max(measured * 1.12, official * 1.04)
    }

    private func exportCSV() {
        guard let run = runner.lastRun else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "memory-bandwidth-\(run.sizeMB)MB-\(run.threads)T.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let iso = ISO8601DateFormatter().string(from: run.startedAt)
            let official = currentChipSpec?.baselineGBps
            var csv = "run_started,size_mb,threads,iterations,mode,avg_GBps,peak_GBps,avg_ms,cpu_GBps,gpu_GBps,official_GBps,pct_of_official\n"
            for r in runner.results {
                let c = r.cpuGBps.map { String(format: "%.2f", $0) } ?? ""
                let g = r.gpuGBps.map { String(format: "%.2f", $0) } ?? ""
                let o = official.map { String(format: "%.0f", $0) } ?? ""
                let pct = official.flatMap { $0 > 0 ? String(format: "%.1f", r.avgGBps / $0 * 100) : nil } ?? ""
                csv += "\(iso),\(run.sizeMB),\(run.threads),\(run.iterations),\(r.mode.rawValue),\(String(format: "%.2f", r.avgGBps)),\(String(format: "%.2f", r.peakGBps)),\(String(format: "%.2f", r.avgMs)),\(c),\(g),\(o),\(pct)\n"
            }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct MemoryBandwidthBenchApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            let lines = Runner().selfTest()
            let text = "[" + lines.joined(separator: ",") + "]\n"
            FileHandle.standardOutput.write(text.data(using: .utf8)!)
            exit(lines.isEmpty ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("Memory Bandwidth Bench" + " v\(appVersion)") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 800)
    }
}
