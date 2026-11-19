// 看门狗：由 launchd 托管（KeepAlive）的独立进程，兜底恢复被禁用的物理屏
// 触发条件（存在禁用记录时）：主程序不在 / 心跳超时（卡死，先强杀再恢复）/ RustDesk 已断开 5 秒
import CoreGraphics
import Foundation

enum Heartbeat {
    static let appURL = ConfigStore.dir.appendingPathComponent("heartbeat-app")
    static let watchdogURL = ConfigStore.dir.appendingPathComponent("heartbeat-watchdog")

    static func beat(_ url: URL) {
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
    }

    /// (pid, 距上次心跳秒数)
    static func read(_ url: URL) -> (pid: pid_t, age: TimeInterval)? {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return (pid, Date().timeIntervalSince(m))
    }

    static func alive(_ url: URL, maxAge: TimeInterval) -> Bool {
        guard let hb = read(url) else { return false }
        return kill(hb.pid, 0) == 0 && hb.age < maxAge
    }
}

enum Watchdog {
    static let interval: TimeInterval = 5
    static let appMaxAge: TimeInterval = 10
    static let sessionGoneLimit: TimeInterval = 5

    static var isRunning: Bool { Heartbeat.alive(Heartbeat.watchdogURL, maxAge: interval * 2 + 2) }

    private static let assumeConnected = ProcessInfo.processInfo.environment["RUSTDISPLAY_WATCHDOG_ASSUME_CONNECTED"] == "1"

    static func run() -> Never {
        try? FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        Log.info("[看门狗] 启动 pid=\(getpid())")
        var sessionGoneSince: Date?
        while true {
            autoreleasepool {
                Heartbeat.beat(Heartbeat.watchdogURL)
                guard PhysicalDisplays.pending != nil else { sessionGoneSince = nil; return }

                let hb = Heartbeat.read(Heartbeat.appURL)
                let appExists = hb.map { kill($0.pid, 0) == 0 } ?? false
                let appHealthy = appExists && (hb?.age ?? .infinity) < appMaxAge
                let active = assumeConnected || RustDeskProbe.hasActiveSession()
                sessionGoneSince = active ? nil : (sessionGoneSince ?? Date())

                if !appHealthy {
                    if appExists, let pid = hb?.pid {
                        Log.info("[看门狗] 主程序心跳超时 \(Int(hb?.age ?? 0)) 秒，强制结束 pid=\(pid)")
                        kill(pid, SIGKILL)
                    }
                    PhysicalDisplays.restore(reason: "看门狗：主程序\(appExists ? "卡死" : "不在")")
                } else if let t = sessionGoneSince, Date().timeIntervalSince(t) > sessionGoneLimit {
                    PhysicalDisplays.restore(reason: "看门狗：RustDesk 已断开但物理屏未恢复")
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

/// 看门狗的 LaunchAgent 安装（~/Library/LaunchAgents + launchctl）
enum WatchdogAgent {
    static let label = "com.rustcomp.rustdisplay.watchdog-agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RustDisplayWatchdog") }
    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    private static var plistData: Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--watchdog"],
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.rustcomp.rustdisplay"],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    static func ensureInstalled() {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Log.info("⚠️ 找不到看门狗可执行文件，跳过安装：\(executable.path)")
            return
        }
        let data = plistData
        let changed = (try? Data(contentsOf: plistURL)) != data
        if changed {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: plistURL, options: .atomic)
        }
        if changed && isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        if !isLoaded {
            let rc = launchctl(["bootstrap", domain, plistURL.path])
            Log.info(rc == 0 ? "✅ 看门狗已加载" : "⚠️ 看门狗加载失败（launchctl 返回 \(rc)），可能被「登录项与扩展」中的后台开关关闭")
        }
    }

    static func stopForSession() {
        guard isLoaded else { return }
        launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: Heartbeat.watchdogURL)
        Log.info("已停止本次登录中的看门狗")
    }

    static func uninstall() {
        let loaded = isLoaded
        if loaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        let existed = FileManager.default.fileExists(atPath: plistURL.path)
        try? FileManager.default.removeItem(at: plistURL)
        if loaded || existed { Log.info("已卸载看门狗") }
        try? FileManager.default.removeItem(at: Heartbeat.watchdogURL)
    }
}
