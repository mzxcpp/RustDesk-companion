import Foundation

/// 一条活跃的 RustDesk 传入远控会话（从 server 日志解析）
public struct RustDeskSession: Equatable, Hashable, Sendable {
    public let connId: Int
    public let peerIP: String
    public let openedAt: Date

    public init(connId: Int, peerIP: String, openedAt: Date = Date()) {
        self.connId = connId
        self.peerIP = peerIP
        self.openedAt = openedAt
    }
}

/// 增量解析 RustDesk server 日志（~/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log）
/// 典型日志行：
/// - `[2026-01-01 12:00:00.000000 +08:00] DEBUG [src/server/connection.rs:1507] #101 Connection opened from 100.64.0.10:51000.`
/// - `[2026-01-01 12:00:10.000000 +08:00] INFO [src/server/connection.rs:5319] #101 Connection closed: Peer close`
/// - `[2026-01-01 12:00:10.001000 +08:00] INFO [src/server/connection.rs:1250] #101 connection loop exited`
/// - `[2026-01-01 12:00:10.002000 +08:00] INFO [libs/scrap/src/common/codec.rs:172] update:Remove(101)`
/// - `[2026-01-01 12:00:30.000000 +08:00] INFO [src/rendezvous_mediator.rs:309] server restart`
public struct RustDeskLogParser {
    public private(set) var activeByID: [Int: RustDeskSession] = [:]
    /// 最近连入过的来源 IP（按最新在前排序、去重，最多保留 20 条）
    public private(set) var recentPeerIPs: [String] = []

    public init() {}

    /// 当前活跃会话（按 connId 升序，确保主会话选择稳定）
    public var activeSessions: [RustDeskSession] {
        activeByID.values.sorted { $0.connId < $1.connId }
    }

    public mutating func resetActive() {
        activeByID.removeAll()
    }

    /// 喂入多行日志文本（例如启动时扫全文件或每次增量 tail）
    public mutating func feed(text: String, now: Date = Date()) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            self.feed(line: String(rawLine), now: now)
        }
    }

    /// 喂入单行日志
    public mutating func feed(line: String, now: Date = Date()) {
        guard !line.isEmpty else { return }

        // 1. 本地服务启动/重启：清空所有旧连接，防止残留假活跃状态
        if line.contains("start --server") || line.contains("try start server") || line.contains("Started ipc server at path:") {
            activeByID.removeAll()
            return
        }

        // 2. 新连接打开：#<id> Connection opened from <addr>.
        if let opened = parseOpened(line, now: now) {
            activeByID[opened.connId] = opened
            recordRecentIP(opened.peerIP)
            return
        }

        // 3. 连接关闭：#<id> Connection closed: / #<id> connection loop exited / update:Remove(<id>)
        if let closedID = parseClosed(line) {
            activeByID.removeValue(forKey: closedID)
            return
        }
    }

    private mutating func recordRecentIP(_ ip: String) {
        guard !ip.isEmpty else { return }
        recentPeerIPs.removeAll { $0 == ip }
        recentPeerIPs.insert(ip, at: 0)
        if recentPeerIPs.count > 20 {
            recentPeerIPs.removeLast(recentPeerIPs.count - 20)
        }
    }

    /// 归一化地址：去掉端口、方括号及 IPv4-mapped IPv6 前缀 `::ffff:`
    public static func normalizeIP(_ rawAddress: String) -> String {
        var s = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") || s.hasSuffix(",") {
            s.removeLast()
        }
        // 形如 [::ffff:100.64.0.10]:51000 或 [2001:db8::1]:51000
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: s.startIndex)..<close])
        } else if let colon = s.lastIndex(of: ":"), s.firstIndex(of: ":") == colon {
            // IPv4:port
            s = String(s[..<colon])
        }
        if s.lowercased().hasPrefix("::ffff:") {
            s = String(s.dropFirst(7))
        }
        return s
    }

    private func parseOpened(_ line: String, now: Date) -> RustDeskSession? {
        if line.contains("[src/client") || line.contains("ui_session") {
            return nil
        }
        guard let marker = line.range(of: " Connection opened from ") else { return nil }
        guard let connId = extractHashID(before: marker.lowerBound, in: line) else { return nil }
        let rest = String(line[marker.upperBound...])
        let ip = RustDeskLogParser.normalizeIP(rest)
        guard !ip.isEmpty else { return nil }
        return RustDeskSession(connId: connId, peerIP: ip, openedAt: now)
    }

    /// 解析 ~/Library/Logs/RustDesk/cm/RustDesk_rCURRENT.log 判断 Connection Manager 当前是否有活跃连接任务
    public static func hasActiveCMTask(in cmLogText: String) -> Bool {
        var active = 0
        for line in cmLogText.split(whereSeparator: \.isNewline) {
            if line.contains("Started ipc_cm server") {
                active = 0
            } else if line.contains("ipc task begin") {
                active += 1
            } else if line.contains("ipc task end") {
                active = max(0, active - 1)
            }
        }
        return active > 0
    }

    private func parseClosed(_ line: String) -> Int? {
        if let marker = line.range(of: " Connection closed") {
            return extractHashID(before: marker.lowerBound, in: line)
        }
        if let marker = line.range(of: " connection loop exited") {
            return extractHashID(before: marker.lowerBound, in: line)
        }
        if let marker = line.range(of: "update:Remove(") {
            let after = line[marker.upperBound...]
            if let end = after.firstIndex(of: ")"), let id = Int(after[..<end]) {
                return id
            }
        }
        return nil
    }

    /// 从 `... #399` 往前提取数字 ID
    private func extractHashID(before index: String.Index, in line: String) -> Int? {
        let prefix = line[..<index]
        guard let hash = prefix.lastIndex(of: "#") else { return nil }
        let digits = prefix[prefix.index(after: hash)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
