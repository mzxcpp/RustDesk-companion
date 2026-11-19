// 监测 RustDesk 传入远控会话：
// 1. 增量跟踪 RustDesk server 与主日志（兼容后台服务 --server 模式与直接运行 RustDesk.app 模式）
// 2. 通过 Darwin libproc + IPC PID 文件与 cm 日志状态零子进程检测会话活跃度
import Darwin
import Foundation
import RustDeskCore

enum RustDeskProbe {
    static var candidateServerLogPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Logs/RustDesk/server/RustDesk_rCURRENT.log"),
            home.appendingPathComponent("Library/Logs/RustDesk/RustDesk_rCURRENT.log"),
            URL(fileURLWithPath: "/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log"),
        ]
    }

    static var existingServerLogURLs: [URL] {
        candidateServerLogPaths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var serverLogURL: URL? {
        existingServerLogURLs.first
    }

    static var cmLogURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RustDesk/cm/RustDesk_rCURRENT.log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func isRustDeskPID(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return false }
        return String(cString: buf).contains("RustDesk")
    }

    private static func readPIDFile(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func cmPID() -> pid_t? {
        let uid = getuid()
        let paths = [
            "/tmp/RustDesk-\(uid)/ipc_cm.pid",
            "/tmp/RustDesk/ipc_cm.pid",
        ]
        for path in paths {
            if let pid = readPIDFile(path), isRustDeskPID(pid) {
                return pid
            }
        }
        return nil
    }

    /// 检查 Connection Manager (`--cm`) 是否存在且正在处理远控会话
    static func isCMProcessRunning() -> Bool {
        guard cmPID() != nil else { return false }
        if let url = cmLogURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            return RustDeskLogParser.hasActiveCMTask(in: text)
        }
        return true
    }

    /// 检查 RustDesk 宿主机端进程是否在运行（兼容 LaunchAgent 服务模式与桌面 App 直连模式）
    static func isServerProcessRunning() -> Bool {
        let uid = getuid()
        let ipcPaths = [
            "/tmp/RustDesk-\(uid)/ipc.pid",
            "/tmp/RustDesk/ipc.pid",
        ]
        for path in ipcPaths {
            if let pid = readPIDFile(path), isRustDeskPID(pid) {
                return true
            }
        }
        let byteSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteSize > 0 else { return false }
        let count = Int(byteSize) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: count)
        let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(count * MemoryLayout<pid_t>.stride))
        guard actualBytes > 0 else { return false }
        let actualCount = Int(actualBytes) / MemoryLayout<pid_t>.stride
        let currentCM = cmPID()
        for pid in pids.prefix(actualCount) where pid > 0 && pid != currentCM {
            if isRustDeskPID(pid) {
                return true
            }
        }
        return false
    }

    /// 供看门狗或命令行探针一次性判断当前是否存在活跃远控会话
    static func hasActiveSession() -> Bool {
        if isCMProcessRunning() { return true }
        guard isServerProcessRunning() else { return false }
        let now = Date()
        for url in existingServerLogURLs {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(mtime) <= 3600 else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var parser = RustDeskLogParser()
            parser.feed(text: text, now: now)
            if !parser.activeSessions.isEmpty {
                return true
            }
        }
        return false
    }

    /// 扫描 server 与主日志目录，返回最近连入过的来源 IP（最新在前）
    static func scanRecentPeerIPs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent("Library/Logs/RustDesk/server", isDirectory: true),
            home.appendingPathComponent("Library/Logs/RustDesk", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/RustDesk/server", isDirectory: true),
        ]
        var candidates: [(url: URL, mtime: Date)] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let logs = items
                .filter { $0.pathExtension == "log" }
                .map { url -> (url: URL, mtime: Date) in
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (url, mtime)
                }
                .sorted { $0.mtime < $1.mtime }
            candidates.append(contentsOf: logs.suffix(5))
        }
        var seen = Set<String>()
        let sortedFiles = candidates
            .sorted { $0.mtime < $1.mtime }
            .filter { seen.insert($0.url.path).inserted }
        var parser = RustDeskLogParser()
        for item in sortedFiles {
            if let text = try? String(contentsOf: item.url, encoding: .utf8) {
                parser.feed(text: text)
            }
        }
        return parser.recentPeerIPs
    }
}

final class RustDeskMonitor {
    var onConnect: ((String?) -> Void)?
    var onPeerChanged: ((String?) -> Void)?
    var onDisconnect: (() -> Void)?

    private(set) var connected = false
    private(set) var currentPeerIP: String?
    private(set) var recentPeerIPs: [String] = []

    private var timer: Timer?
    private var state = RustDeskConnectionState()
    private let queue = DispatchQueue(label: "rustdisplay.monitor", qos: .utility)
    private var pollInFlight = false

    private struct LogTailer {
        var parser = RustDeskLogParser()
        var trackedInode: UInt64?
        var trackedOffset: UInt64 = 0
        var lineBuffer = ""
        var initialized = false
        var lastMTime: Date = .distantPast
    }

    private var tailers: [String: LogTailer] = [:]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !pollInFlight else { return }
        pollInFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.pollSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                self.recentPeerIPs = snapshot.recentIPs
                self.apply(sessions: snapshot.sessions, cmActive: snapshot.cmActive)
            }
        }
    }

    private struct Snapshot {
        let sessions: [RustDeskSession]
        let cmActive: Bool
        let recentIPs: [String]
    }

    private func pollSnapshot() -> Snapshot {
        let cmActive = RustDeskProbe.isCMProcessRunning()
        let urls = RustDeskProbe.existingServerLogURLs
        let validPaths = Set(urls.map(\.path))
        tailers = tailers.filter { validPaths.contains($0.key) }

        for url in urls {
            tail(url: url, cmActive: cmActive)
        }

        var mergedSessions = tailers.values
            .flatMap { $0.parser.activeSessions }
            .sorted { $0.openedAt < $1.openedAt }

        if !mergedSessions.isEmpty && !cmActive && !RustDeskProbe.isServerProcessRunning() {
            for key in tailers.keys {
                tailers[key]?.parser.resetActive()
            }
            mergedSessions.removeAll()
        }

        var seenIPs = Set<String>()
        var mergedIPs: [String] = []
        for tailer in tailers.values.sorted(by: { $0.lastMTime > $1.lastMTime }) {
            for ip in tailer.parser.recentPeerIPs where seenIPs.insert(ip).inserted {
                mergedIPs.append(ip)
            }
        }

        return Snapshot(
            sessions: mergedSessions,
            cmActive: cmActive,
            recentIPs: mergedIPs
        )
    }

    private func tail(url: URL, cmActive: Bool) {
        let path = url.path
        var tailer = tailers[path] ?? LogTailer()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return }
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        tailer.lastMTime = mtime

        let rotated = (tailer.trackedInode != nil && tailer.trackedInode != inode) || (fileSize < tailer.trackedOffset)
        if rotated {
            tailer.trackedInode = inode
            tailer.trackedOffset = 0
            tailer.lineBuffer = ""
            tailer.parser.resetActive()
        } else if tailer.trackedInode == nil {
            tailer.trackedInode = inode
        }

        if fileSize > tailer.trackedOffset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: tailer.trackedOffset)
                let data = try handle.readToEnd() ?? Data()
                tailer.trackedOffset += UInt64(data.count)
                if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
                    let combined = tailer.lineBuffer + chunk
                    var lines = combined.components(separatedBy: "\n")
                    if !combined.hasSuffix("\n") {
                        tailer.lineBuffer = lines.popLast() ?? ""
                    } else {
                        tailer.lineBuffer = ""
                    }
                    let now = Date()
                    for line in lines {
                        tailer.parser.feed(line: line, now: now)
                    }
                }
            } catch {
                // 忽略单次读取失败，下一轮继续
            }
        }

        if !tailer.initialized {
            // 首次启动时若日志文件距上次更新已超过 5 秒且 cm 未活跃，清理历史残留未闭合连接（保留 recentPeerIPs）
            if !cmActive && Date().timeIntervalSince(mtime) > 5 {
                tailer.parser.resetActive()
            }
            tailer.initialized = true
        }

        tailers[path] = tailer
    }

    private func apply(sessions: [RustDeskSession], cmActive: Bool) {
        switch state.update(activeSessions: sessions, cmProcessActive: cmActive, now: Date()) {
        case .connected:
            connected = true
            currentPeerIP = state.currentPeerIP
            Log.info("检测到 RustDesk 连入（来源：\(currentPeerIP ?? "未知")，cm=\(cmActive)）")
            onConnect?(currentPeerIP)
        case .peerChanged:
            currentPeerIP = state.currentPeerIP
            Log.info("检测到 RustDesk 控制端变化（来源：\(currentPeerIP ?? "未知")）")
            onPeerChanged?(currentPeerIP)
        case .disconnected:
            connected = false
            currentPeerIP = nil
            Log.info("检测到 RustDesk 断开")
            onDisconnect?()
        case nil:
            break
        }
    }
}
