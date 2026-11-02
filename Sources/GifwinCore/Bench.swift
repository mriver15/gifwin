import Darwin
import Foundation

/// Measures the encoder on a synthetic window, so the performance budgets can be checked by a script
/// with no screen and no permission. It exercises the real pipeline (source, intake, encoder, writer) and
/// subtracts the time spent inventing frames, which a real capture does not pay.
public enum Bench {
    public enum Scene: String, CaseIterable {
        /// A mostly static app window: a progress bar, a blinking field, a moving pointer.
        case typical
        /// Everything changes every frame: a worst case no real window sustains.
        case stress
    }

    struct Generator {
        let width: Int, height: Int
        let base: [UInt32]
        let scene: Scene

        init(width: Int, height: Int, scene: Scene) {
            self.width = width; self.height = height; self.scene = scene
            var px = [UInt32](repeating: 0xFFF5_F5F7, count: width * height)
            for y in 0..<(height / 14) { for x in 0..<width { px[y * width + x] = 0xFF1E_3C8C } }
            var seed: UInt64 = 0x9E37_79B9
            for row in 0..<((height * 11 / 12) / 22) {          // grey bars standing in for lines of text
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let len = 80 + Int(seed >> 33) % (width - 200)
                let y0 = height / 12 + row * 22
                for y in y0..<min(height, y0 + 10) { for x in 24..<(24 + len) { px[y * width + x] = row % 3 == 0 ? 0xFF28_2830 : 0xFF5A_5A64 } }
            }
            base = px
        }

        func frame(_ i: Int) -> [UInt32] {
            var f = base
            switch scene {
            case .typical:
                for y in (height - 30)..<(height - 20) { for x in 24..<(24 + (i * 6) % (width - 48)) { f[y * width + x] = 0xFF34_A853 } }
                let px = 40 + (i * 9) % (width - 80), py = 120 + (i * 5) % (height - 240)
                for y in py..<(py + 14) { for x in px..<(px + 10) { f[y * width + x] = 0xFF00_0000 } }
                if i % 4 < 2 { for y in 200..<216 { for x in 600..<604 { f[y * width + x] = 0xFF00_0000 } } }
            case .stress:
                let shift = (i * 7) % 220
                for y in (height / 12)..<height {
                    let src = ((y - height / 12 + shift) % (height - height / 12)) + height / 12
                    for x in 0..<width { f[y * width + x] = base[src * width + x] ^ UInt32(i & 0x3F) &* 0x0001_0101 }
                }
            }
            return f
        }
    }

    /// CPU seconds this process has used, user plus system.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// Peak resident set size of this process, in MB.
    static func peakRSS() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576   // macOS reports bytes
    }

    /// Resident set size right now, in MB (not the peak).
    static func currentRSS() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// A 30 s rolling buffer filled from a synthetic window, then left holding: the cost of watching.
    public static func ring(rolling: Double, feedSeconds: Double, width: Int, height: Int) async -> [String: Any] {
        var settings = Quality.balanced.settings
        settings.trim = false
        let before = currentRSS()
        let gen = Generator(width: width, height: height, scene: .typical)
        let count = Int(feedSeconds * settings.fps)
        let info = WindowInfo(id: 1, app: "Bench", bundleID: "bench", pid: 0, title: "", width: width, height: height)
        let source = LazySource(count: count, width: width, height: height, fps: settings.fps) { gen.frame($0) }
        let watcher = try? await Watcher.start(source: source, info: info, rolling: rolling, settings: settings)
        let after = currentRSS()
        return ["rolling_seconds": rolling, "fed_seconds": feedSeconds, "held_seconds": ((watcher?.heldSeconds ?? 0) * 10).rounded() / 10,
                "held_mb": (Double(watcher?.heldBytes ?? 0) / 1_048_576 * 100).rounded() / 100,
                "rss_before_mb": (before * 10).rounded() / 10, "rss_now_mb": (after * 10).rounded() / 10]
    }

    static func wall() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }

    public static func run(seconds: Double, width: Int, height: Int, runs: Int, quality: Quality) async -> [String: Any] {
        var settings = quality.settings
        settings.trim = true
        let frameCount = Int(seconds * settings.fps)
        var report: [String: Any] = ["width": width, "height": height, "seconds": seconds, "fps": settings.fps,
                                     "quality": quality.rawValue, "frames_offered": frameCount, "runs": runs]
        for scene in Scene.allCases {
            let gen = Generator(width: width, height: height, scene: scene)
            var inventing = 0.0
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("gifwin-bench-\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: url) }

            // Frames are made as they are consumed, so memory is not inflated by a pre-built clip.
            let source = LazySource(count: frameCount, width: width, height: height, fps: settings.fps) { i in
                let t0 = wall(); let f = gen.frame(i); inventing += wall() - t0; return f
            }
            let cpu0 = cpuSeconds()
            let wall0 = wall()
            let result = try? await Capture.record(source: source, seconds: 3600, to: url, settings: settings)
            let cpu = cpuSeconds() - cpu0 - inventing
            let elapsed = wall() - wall0 - inventing

            // How long after the last frame the file is ready: finishing a clip, repeated.
            var tails: [Double] = []
            for _ in 0..<runs {
                let short = LazySource(count: Int(settings.fps * 2), width: width, height: height, fps: settings.fps) { gen.frame($0) }
                let u = url.deletingLastPathComponent().appendingPathComponent("gifwin-tail-\(UUID().uuidString).gif")
                defer { try? FileManager.default.removeItem(at: u) }
                let intake = Intake(settings: settings) { w, h in try GIFWriter(url: u, width: w, height: h) }
                try? await short.start { p, w, h, t in intake.feed(p, w, h, t) }
                let t0 = wall()
                _ = try? intake.finish(endTime: short.now)
                tails.append((wall() - t0) * 1000)
            }
            tails.sort()
            let p95 = tails.isEmpty ? 0 : tails[min(tails.count - 1, Int(Double(tails.count) * 0.95))]

            report[scene.rawValue] = [
                "frames_written": result?.frames ?? 0,
                "bytes": result?.bytes ?? 0,
                "bytes_per_second": Int(Double(result?.bytes ?? 0) / seconds),
                "encode_ms_per_offered_frame": (cpu / Double(max(frameCount, 1)) * 1000 * 100).rounded() / 100,
                // CPU the encoder would use keeping up with a live source at this rate: its time per frame
                // times frames per second, as a share of one core.
                "cpu_percent_of_one_core": (cpu / seconds * 100 * 10).rounded() / 10,
                "wall_seconds_to_encode": (elapsed * 100).rounded() / 100,
                "finish_ms_p95": (p95 * 10).rounded() / 10,
            ] as [String: Any]
        }
        report["peak_rss_mb"] = (peakRSS() * 10).rounded() / 10
        report["pid"] = Int(getpid())
        return report
    }
}

/// Frames made on demand, delivered all at once like `SyntheticSource`.
final class LazySource: FrameSource {
    private let count: Int, width: Int, height: Int, fps: Double
    private let make: (Int) -> [UInt32]
    private var delivered = false
    init(count: Int, width: Int, height: Int, fps: Double, make: @escaping (Int) -> [UInt32]) {
        self.count = count; self.width = width; self.height = height; self.fps = fps; self.make = make
    }
    func start(_ handler: @escaping @Sendable ([UInt32], Int, Int, Double) -> Void) async throws {
        for i in 0..<count { handler(make(i), width, height, Double(i) / fps) }
        delivered = true
    }
    func stop() async {}
    var hasEnded: Bool { delivered }
    var endReason: String? { delivered ? "ended" : nil }
    var isScripted: Bool { true }
    var now: Double { Double(count) / fps }
}
