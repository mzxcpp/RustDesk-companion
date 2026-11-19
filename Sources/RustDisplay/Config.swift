// 虚拟屏配置、按来源 IP 匹配的设备规则与持久化
import Foundation

/// 虚拟屏目标规格（传给 DisplayManager）
struct DisplayProfile: Codable, Equatable, Hashable {
    var label: String
    /// 横屏原生像素（HiDPI 开启时逻辑分辨率为宽/2 × 高/2）
    var width: Int
    var height: Int
    var hiDPI: Bool = true

    static let validSize = 320...16384
    var hasValidSize: Bool { Self.validSize.contains(width) && Self.validSize.contains(height) }
    var sizeLabel: String { "\(width)×\(height)\(hiDPI ? " 高清" : "")" }
}

/// 常用分辨率预设
struct ResolutionPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let hiDPI: Bool

    static let all: [ResolutionPreset] = [
        .init(id: "2560x1600", title: "16:10 推荐", width: 2560, height: 1600, hiDPI: true),
        .init(id: "2560x1440", title: "2K 16:9", width: 2560, height: 1440, hiDPI: true),
        .init(id: "1920x1080", title: "1080p", width: 1920, height: 1080, hiDPI: false),
        .init(id: "2360x1640", title: "iPad Air 11\"", width: 2360, height: 1640, hiDPI: true),
        .init(id: "2752x2064", title: "iPad Pro 13\"", width: 2752, height: 2064, hiDPI: true),
        .init(id: "2556x1180", title: "iPhone", width: 2556, height: 1180, hiDPI: true),
    ]
}

/// 按来源 IP（例如 Tailscale / 局域网 IP）定制的设备规则
struct PeerRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 匹配的来源 IP（归一化后，如 100.64.0.10）
    var peerIP: String
    /// 用户备注名（如 "iPad Pro"、"公司电脑"）
    var name: String
    /// true = 自定义虚拟屏分辨率；false = 不创建虚拟屏（交给 RustDesk 原样显示）
    var useVirtualDisplay: Bool = true
    var width: Int = 2560
    var height: Int = 1600
    var hiDPI: Bool = true

    var hasValidSize: Bool { DisplayProfile.validSize.contains(width) && DisplayProfile.validSize.contains(height) }

    var displayProfile: DisplayProfile? {
        guard useVirtualDisplay, hasValidSize else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? peerIP : name
        return DisplayProfile(label: label, width: width, height: height, hiDPI: hiDPI)
    }
}

struct AppConfig: Codable {
    /// 默认虚拟屏分辨率（任何未单独配置的 RustDesk 连入均使用此配置）
    var defaultWidth: Int = 2560
    var defaultHeight: Int = 1600
    var defaultHiDPI: Bool = true
    /// 未匹配到独立规则的设备是否自动创建默认虚拟屏（默认开启，开箱即用）
    var useDefaultForUnknownPeers: Bool = true

    /// 按来源 IP 配置的独立设备规则
    var peerRules: [PeerRule] = []

    /// 是否暂停自动创建虚拟屏
    var paused: Bool = false
    /// 是否将虚拟屏设为主屏（关闭则作为纯扩展副屏，保留本机为主屏）
    var setAsMain: Bool? = false
    var shouldSetAsMain: Bool { setAsMain ?? false }

    /// 远程时关闭物理屏（缺省关闭，在设置里开启）
    var disablePhysical: Bool?
    var shouldDisablePhysical: Bool { disablePhysical ?? false }

    /// 看门狗（兜底恢复物理屏）缺省关闭，只有用户在设置里开启才安装
    var watchdogEnabled: Bool?
    var shouldRunWatchdog: Bool { watchdogEnabled ?? false }

    /// 是否已看过首次启动功能导览
    var tourShown: Bool?

    var defaultProfile: DisplayProfile? {
        let p = DisplayProfile(label: "默认虚拟屏", width: defaultWidth, height: defaultHeight, hiDPI: defaultHiDPI)
        return p.hasValidSize ? p : nil
    }
}

final class ConfigStore {
    static let shared = ConfigStore()

    static let dir: URL = {
        if let envDir = ProcessInfo.processInfo.environment["RUSTDISPLAY_CONFIG_DIR"], !envDir.isEmpty {
            return URL(fileURLWithPath: envDir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RustDisplay", isDirectory: true)
    }()
    private let url = ConfigStore.dir.appendingPathComponent("config.json")

    var config: AppConfig {
        didSet { save() }
    }

    private init() {
        try? FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        config = (try? JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))) ?? AppConfig()
    }

    func rule(forPeerIP ip: String?) -> PeerRule? {
        guard let ip, !ip.isEmpty else { return nil }
        return config.peerRules.first { $0.peerIP.trimmingCharacters(in: .whitespacesAndNewlines) == ip }
    }

    /// 解析某个连入来源对应的虚拟屏规格（nil 表示本次连入不创建虚拟屏）
    func resolveProfile(forPeerIP ip: String?) -> (who: String, profile: DisplayProfile?) {
        if let rule = rule(forPeerIP: ip) {
            let who = rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rule.peerIP : rule.name
            return (who, rule.displayProfile)
        }
        let who = (ip?.isEmpty == false) ? ip! : "RustDesk 远控"
        guard config.useDefaultForUnknownPeers else {
            return (who, nil)
        }
        guard var profile = config.defaultProfile else {
            return (who, nil)
        }
        if let ip, !ip.isEmpty {
            profile.label = ip
        }
        return (who, profile)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: url, options: .atomic)
    }
}
