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
let appTitle = "Memory Bandwidth Bench v\(appVersion)"

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

// MARK: - Automatic UI language detection (Traditional / Simplified Chinese / English)

enum UILang { case zhHant, zhHans, en }

enum L {
    static let lang: UILang = {
        guard let first = Locale.preferredLanguages.first else { return .en }
        if first.contains("Hans") { return .zhHans }
        if first.hasPrefix("zh") { return .zhHant }
        return .en
    }()

    static func t(_ zh: String, _ en: String) -> String {
        switch lang {
        case .en: return en
        case .zhHans: return toHans(zh)
        case .zhHant: return zh
        }
    }

    static func toHans(_ s: String) -> String {
        guard lang == .zhHans else { return s }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, "Hant-Hans" as CFString, false)
        return m as String
    }

    static func threadsSuffix(_ n: Int) -> String { t("\(n) 執行緒", "\(n) threads") }
    static func pass(_ i: Int, _ n: Int, _ mode: String) -> String {
        t("\(mode) 第 \(i)/\(n) 次…", "\(mode): pass \(i)/\(n)…")
    }
    static let specNoteGPU = t("（依 GPU 配置）", "(by GPU config)")
}

var coreSummary: String {
    if performanceCores > 0, efficiencyCores > 0 {
        return "\(performanceCores)P+\(efficiencyCores)E・\(L.threadsSuffix(logicalCores))"
    }
    return L.threadsSuffix(logicalCores)
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
        let sep = L.lang == .en ? "/" : "\u{FF0F}"
        guard let high = highText else { return lowText + " GB/s" }
        switch isHigh {
        case .some(true):
            let note = gpuHighThreshold != nil
                ? L.t("（\(gpuCoreCount) 核 GPU）", "(\(gpuCoreCount)-core GPU)")
                : L.t("（依記憶體容量）", "(by RAM capacity)")
            return high + " GB/s " + note
        case .some(false):
            return lowText + " GB/s"
        case nil:
            return lowText + sep + high + " GB/s " + L.specNoteGPU
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
    var id: String { rawValue }   // stable English key (CSV / debugging)

    var display: String {
        switch self {
        case .read:  return L.t("讀取", "Read")
        case .write: return L.t("寫入", "Write")
        case .writePingPong: return L.t("寫入(乒乓)", "Write (ping-pong)")
        case .copy:  return L.t("複製", "Copy")
        case .cpuGpu: return L.t("CPU+GPU併發", "CPU+GPU concurrent")
        }
    }

    var detail: String {
        switch self {
        case .read:  return L.t("每個執行緒依序讀取自己那片記憶體（8 路展開 uint64 累加，提高在途請求數）",
                                "Each thread scans its own buffer sequentially (8-way unrolled uint64 accumulation to raise outstanding requests)")
        case .write: return L.t("每個執行緒填滿自己那片記憶體（8 路展開寫入）",
                                "Each thread fills its own buffer (8-way unrolled stores)")
        case .writePingPong: return L.t("每次迭代交替寫入兩塊 buffer，強迫上一輪的髒資料在本輪逐出，更貼近真實 DRAM 寫入頻寬",
                                "Alternates two buffers each iteration so the previous round's dirty lines must be evicted this round, closer to sustained DRAM write bandwidth")
        case .copy:  return L.t("memcpy：src → dst，流量計入讀＋寫雙向位元組",
                                "memcpy src to dst; traffic counts both read and write bytes")
        case .cpuGpu: return L.t("CPU 全部執行緒持續掃描＋GPU Metal kernel 同時讀取，合計最接近整機 DRAM 實際上限",
                                 "All CPU threads scan while a Metal kernel reads concurrently; the total is closest to the SoC's real DRAM ceiling")
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
    @Published var statusText = L.t("尚未測試", "Not tested yet")
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
        statusText = L.t("正在停止…", "Stopping…")
    }

    // MARK: Run flow

    func run(sizeMB: Int, threads: Int, iterations: Int, modes: [TestMode]) {
        guard !running else { return }
        stateLock.lock(); cancelRequested = false; stateLock.unlock()

        running = true
        results = []
        errorMessage = nil
        progressTotal = max(1, modes.reduce(0) { $0 + ($1 == .cpuGpu ? iterations * 8 : iterations) })
        progressDone = 0
        statusText = L.t("配置記憶體…", "Allocating memory…")
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
                    self.errorMessage = L.t("無法配置 \(sizeMB) MB ×2 的測試緩衝區，請選擇較小的尺寸。",
                                  "Failed to allocate \(sizeMB) MB x2 test buffers. Please choose a smaller size.")
                }
                return
            }
            defer { free(srcRaw); free(dstRaw) }

            // First touch forces real page allocation; not included in timing
            DispatchQueue.main.async { self.statusText = L.t("暖機中…", "Warming up…") }
            memset(srcRaw, 0xAB, bytes)
            memset(dstRaw, 0xCD, bytes)

            let src = srcRaw.assumingMemoryBound(to: UInt64.self)
            let dst = dstRaw.assumingMemoryBound(to: UInt64.self)
            let words = bytes / MemoryLayout<UInt64>.size

            for mode in modes where mode != .cpuGpu {
                if self.isCancelled { break }
                self.runCPUMode(mode: mode, src: src, dst: dst, bytes: bytes,
                                words: words, threads: threads, iterations: iterations)
            }

            if modes.contains(.cpuGpu), !self.isCancelled {
                self.runCPUPlusGPU(src: src, words: words, bytes: bytes,
                                   threads: threads, iterations: iterations)
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
            DispatchQueue.main.async { self.statusText = L.pass(index, iterations, mode.display) }
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
                self.errorMessage = L.t("Metal 初始化或 GPU 緩衝區配置失敗，已跳過 CPU+GPU 併發測試。",
                                  "Metal initialization or GPU buffer allocation failed; the CPU+GPU concurrent test was skipped.")
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
            DispatchQueue.main.async { self.statusText = L.pass(index, iterations, TestMode.cpuGpu.display) }
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

    /// Single exit path: guarantees the power assertion is released (alloc failure, cancel, etc.)
    private func finishRun() {
        let cancelled = isCancelled
        DispatchQueue.main.async {
            if let token = self.activityToken {
                ProcessInfo.processInfo.endActivity(token)
                self.activityToken = nil
            }
            self.running = false
            self.statusText = cancelled ? L.t("已停止", "Stopped") : L.t("完成", "Done")
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
        case .cpuGpu:
            return 0   // concurrent mode uses measureCPUGPU; unreachable here
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
        }
        return lines
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
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            controls
            if runner.running || runner.progressDone > 0 {
                ProgressView(value: Double(min(runner.progressDone, runner.progressTotal)),
                             total: Double(runner.progressTotal))
                    .progressViewStyle(.linear)
            }
            if let err = runner.errorMessage {
                Text(err).foregroundStyle(.red).font(.callout)
            }
            resultsSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appTitle)
                .font(.title2.weight(.semibold))
            Text("\(machineChip)・\(formatGB(machineRAMBytes)) RAM・\(coreSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let spec = currentChipSpec {
                Text(L.t("原廠規格：記憶體頻寬 \(spec.officialDisplay)（LPDDR 匯流排理論峰值，實測通常約 50–80%）", "Official spec memory bandwidth: \(spec.officialDisplay) (theoretical LPDDR bus peak; real-world results are typically 50–80%)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            GridRow {
                Text(L.t("緩衝區大小", "Buffer size"))
                Picker("", selection: $sizeMB) {
                    ForEach(sizeOptions, id: \.self) { Text("\($0) MB").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(runner.running)
                .help(L.t("小尺寸（16／64 MB）會被 L2 快取吸收，數字會明顯高於真實 DRAM 頻寬；量測 DRAM 請用 256 MB 以上", "Small sizes (16/64 MB) get absorbed by the L2 cache and read far above real DRAM bandwidth; use 256 MB or more to measure DRAM"))
            }
            GridRow {
                Text(L.t("執行緒數", "Threads"))
                Stepper(value: $threads, in: 1...max(1, logicalCores)) {
                    Text("\(threads)").monospacedDigit().frame(minWidth: 24, alignment: .leading)
                }
                .disabled(runner.running)
            }
            GridRow {
                Text(L.t("每項迭代", "Iterations"))
                Stepper(value: $iterations, in: 1...20) {
                    Text("\(iterations)").monospacedDigit().frame(minWidth: 24, alignment: .leading)
                }
                .disabled(runner.running)
            }
            GridRow {
                Text(L.t("測試項目", "Tests"))
                HStack(spacing: 16) {
                    ForEach(TestMode.allCases) { mode in
                        Toggle(isOn: binding(for: mode)) {
                            Text(mode.display).help(mode.detail)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .disabled(runner.running)
            }
            GridRow {
                HStack(spacing: 12) {
                    Button(runner.running ? L.t("測試中…", "Testing…") : L.t("開始測試", "Start Test")) { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(runner.running || selectedModes.isEmpty)

                    Button(L.t("停止", "Stop")) { runner.cancel() }
                        .disabled(!runner.running)

                    Button(L.t("匯出 CSV", "Export CSV")) { exportCSV() }
                        .disabled(runner.results.isEmpty)
                }
                Text(runner.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        let modes = TestMode.allCases.filter { selectedModes.contains($0) }
        guard !modes.isEmpty else {
            runner.errorMessage = L.t("請至少選擇一種測試項目。", "Please select at least one test.")
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
    private var resultsSection: some View {
        if runner.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 42))
                    .foregroundStyle(.tertiary)
                Text(L.t("設定好參數後按「開始測試」", "Configure the options and press Start Test"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(runner.results) { r in
                        BarMark(
                            x: .value(L.t("測試", "Test"), r.mode.display),
                            y: .value("GB/s", r.avgGBps)
                        )
                        .annotation(position: .top) {
                            Text(String(format: "%.1f", r.avgGBps))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let spec = currentChipSpec {
                        RuleMark(y: .value(L.t("原廠", "Official"), spec.baselineGBps))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text(L.t("原廠", "Official") + " " + spec.officialDisplay)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                    }
                }
                .chartYAxisLabel("GB/s")
                .chartYScale(domain: 0...(max(runner.results.map { $0.avgGBps }.max() ?? 1,
                                                  currentChipSpec?.baselineGBps ?? 0) * 1.08))
                .frame(height: 180)

                Table(runner.results) {
                    TableColumn(L.t("測試項目", "Test")) { Text($0.mode.display) }
                    TableColumn(L.t("平均 GB/s", "Avg GB/s")) { Text(String(format: "%.1f", $0.avgGBps)).monospacedDigit() }
                    TableColumn(L.t("峰值 GB/s", "Peak GB/s")) { Text(String(format: "%.1f", $0.peakGBps)).monospacedDigit() }
                    TableColumn(L.t("達原廠 %", "% of Official")) { r in
                        if let spec = currentChipSpec, spec.baselineGBps > 0 {
                            Text(String(format: "%.0f%%", r.avgGBps / spec.baselineGBps * 100)).monospacedDigit()
                                .foregroundStyle(r.avgGBps / spec.baselineGBps >= 0.75 ? .green : .secondary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    TableColumn(L.t("平均耗時 ms", "Avg Time ms")) { Text(String(format: "%.1f", $0.avgMs)).monospacedDigit() }
                    TableColumn(L.t("CPU／GPU 分項", "CPU/GPU Breakdown")) { r in
                        if let c = r.cpuGBps, let g = r.gpuGBps {
                            Text(L.lang == .en ? String(format: "CPU %.1f + GPU %.1f", c, g) : String(format: "CPU %.1f ＋ GPU %.1f", c, g)).monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
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
        WindowGroup(L.t("記憶體頻寬測試", "Memory Bandwidth Bench") + " v\(appVersion)") {
            ContentView()
        }
    }
}
