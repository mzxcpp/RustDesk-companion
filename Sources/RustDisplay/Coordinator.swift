// 连入/断开 → 按来源 IP 或默认配置选虚拟屏规格 → 自动扩展虚拟屏 / 断开还原
import AppKit

final class Coordinator {
    let monitor = RustDeskMonitor()
    let display = DisplayManager()
    private let store = ConfigStore.shared

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var currentLabel: String?
    /// 手动常驻虚拟屏开关（方便用户不连入时测试或临时扩展一块虚拟屏）
    private(set) var manualActive = false

    /// 调试：模拟连入的来源 IP（不依赖 RustDesk）
    var simulatedPeerIP: String?

    var connected: Bool { monitor.connected || simulatedPeerIP != nil }

    func start() {
        display.shouldSetAsMain = { [weak self] in self?.store.config.shouldSetAsMain ?? false }
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] ip in self?.handleConnect(peerIP: ip) }
        monitor.onPeerChanged = { [weak self] ip in self?.handleConnect(peerIP: ip) }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.start()
    }

    /// 只有真实/模拟远程连接期间才允许关闭物理屏（手动测试虚拟屏时不熄灭物理屏，防止误操作）
    var physicalDisableAllowed: Bool {
        connected && store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.wedged { return "⛔️ 屏幕设置无响应，请重启 Mac" }
        if manualActive && !connected {
            if let c = display.current, display.isActive {
                return "手动虚拟屏已开启 · \(c.sizeLabel)"
            }
            return "正在准备手动虚拟屏…"
        }
        if store.config.paused { return "自动虚拟屏已暂停：连入时不做调整" }
        guard connected else { return "等待 RustDesk 远控连入中" }
        let who = currentLabel ?? "RustDesk 远控"
        if let c = display.current, display.isActive {
            let mode = (store.config.shouldSetAsMain || display.physicalOff) ? "主屏" : "扩展屏"
            return "\(who) 已连接 · 虚拟屏 \(c.sizeLabel)（\(mode)）\(display.physicalOff ? " · 物理屏已关闭" : "")"
        }
        return "\(who) 已连接 · 未启用虚拟屏"
    }

    // MARK: - 事件

    func handleConnect(peerIP: String?) {
        let effectiveIP = simulatedPeerIP ?? peerIP
        guard !store.config.paused else {
            currentLabel = effectiveIP ?? "RustDesk 远控"
            onChange?()
            return
        }
        let resolved = store.resolveProfile(forPeerIP: effectiveIP)
        currentLabel = resolved.who
        Log.info("应用远控配置：来源=\(resolved.who)，虚拟屏=\(resolved.profile?.sizeLabel ?? "不创建")")
        apply(resolved.profile)
    }

    func handleDisconnect() {
        currentLabel = nil
        if manualActive {
            // 如果用户手动开启了虚拟屏，则回退到手动虚拟屏（同时恢复物理屏）
            apply(store.config.defaultProfile)
        } else {
            display.remove()
        }
        onChange?()
    }

    private func apply(_ profile: DisplayProfile?) {
        defer { onChange?() }
        guard let profile, profile.hasValidSize else {
            if display.isActive { display.remove() }
            return
        }
        if display.matches(profile) {
            display.reevaluateTopology()
            return
        }
        display.create(profile)
    }

    // MARK: - 菜单与设置操作

    func setManualActive(_ on: Bool) {
        manualActive = on
        Log.info("手动虚拟屏 → \(on ? "开" : "关")")
        if on {
            apply(store.config.defaultProfile)
        } else if !connected {
            display.remove()
            onChange?()
        } else {
            onChange?()
        }
    }

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            if !manualActive { display.remove() }
        } else if connected {
            handleConnect(peerIP: monitor.currentPeerIP)
        }
        onChange?()
    }

    func setAsMain(_ on: Bool) {
        store.config.setAsMain = on
        Log.info("设置：将虚拟屏设为主屏 → \(on ? "开" : "关")")
        display.reevaluateTopology()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.onChange?() }
    }

    func configChanged() {
        if connected, !store.config.paused {
            handleConnect(peerIP: monitor.currentPeerIP)
        } else if manualActive {
            apply(store.config.defaultProfile)
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { display.reevaluateTopology() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        manualActive = false
        display.remove(completion: completion)
    }
}
