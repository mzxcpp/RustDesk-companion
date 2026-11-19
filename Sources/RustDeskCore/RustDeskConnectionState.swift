import Foundation

/// 合并 RustDesk server 日志活跃会话与 `--cm` 进程状态，带断开防抖（避免重连或切屏期间反复拆建虚拟屏）
public struct RustDeskConnectionState {
    public enum Event: Equatable {
        case connected
        case peerChanged
        case disconnected
    }

    public private(set) var connected = false
    public private(set) var currentPeerIP: String?
    private var inactiveSince: Date?
    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 1.5) {
        self.debounce = debounce
    }

    /// - Parameters:
    ///   - activeSessions: 从 server 日志解析出的当前活跃连接
    ///   - cmProcessActive: 是否检测到 `RustDesk --cm` 进程正在运行
    ///   - now: 当前时间
    public mutating func update(activeSessions: [RustDeskSession], cmProcessActive: Bool, now: Date) -> Event? {
        let primaryIP = activeSessions.first?.peerIP
        let isActive = !activeSessions.isEmpty || cmProcessActive

        if isActive {
            inactiveSince = nil
            if !connected {
                connected = true
                currentPeerIP = primaryIP
                return .connected
            }
            if let ip = primaryIP, ip != currentPeerIP {
                currentPeerIP = ip
                return .peerChanged
            }
        } else if connected {
            let since = inactiveSince ?? now
            inactiveSince = since
            if now.timeIntervalSince(since) >= debounce {
                connected = false
                currentPeerIP = nil
                inactiveSince = nil
                return .disconnected
            }
        }
        return nil
    }
}
