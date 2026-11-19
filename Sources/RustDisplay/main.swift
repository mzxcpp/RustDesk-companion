// RustDesk 伴侣：本机被 RustDesk 远控时，自动拓展虚拟屏（可选设为主屏或关闭物理屏），断开后还原
// 调试：RustDisplay --probe-rustdesk                   探测本机 RustDesk 日志、进程与近期来源 IP
//      RustDisplay --simulate "<ip或A>B>" [秒数=6]     模拟一次连入/断开（不依赖真实远控）
//      RustDisplay --render-settings <目录>            渲染设置窗口各面板为 PNG
//      RustDisplay --render-tour <目录>                渲染功能导览配图（Assets/Tour）
//      RustDisplay --render-tour-ui <配图目录> <输出目录> 渲染 TourKit 界面为 PNG
//      RustDisplay --render-about <png>                渲染「关于」窗口
//      RustDisplay --selftest-settings                 自测设置窗口与状态联动
//      RustDisplay --open-settings [面板]               启动后直接打开设置窗口
//      RustDisplay --tour                              只展示功能导览
//      RustDisplay --watchdog                          看门狗模式（由 launchd 托管）
import AppKit
import Carbon.HIToolbox
import SwiftUI

if CommandLine.arguments.contains("--watchdog") { Watchdog.run() }

if CommandLine.arguments.contains("--probe-rustdesk") {
    let logs = RustDeskProbe.existingServerLogURLs.map(\.path)
    print("serverLogs: \(logs)")
    print("cmLog: \(RustDeskProbe.cmLogURL?.path ?? "none")")
    print("serverRunning: \(RustDeskProbe.isServerProcessRunning())")
    print("cmRunning: \(RustDeskProbe.isCMProcessRunning())")
    print("activeSession: \(RustDeskProbe.hasActiveSession())")
    print("recentPeerIPs: \(RustDeskProbe.scanRecentPeerIPs())")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()
    let settings = SettingsWindowController()
    let tour = TourController()
    var statusBar: StatusBarController?
    private var heartbeatTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var terminating = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("启动 RustDisplay，配置目录：\(ConfigStore.dir.path)")
        statusBar = StatusBarController(coordinator: coordinator,
                                        openSettings: { [weak self] in self?.settings.show(pane: $0) })
        settings.onConfigChanged = { [weak self] in self?.coordinator.configChanged() }
        settings.setDisablePhysical = { [weak self] in self?.coordinator.setDisablePhysical($0) }
        settings.setPaused = { [weak self] in self?.coordinator.setPaused($0) }
        settings.setMainDisplay = { [weak self] in self?.coordinator.setAsMain($0) }
        settings.setManualActive = { [weak self] in self?.coordinator.setManualActive($0) }
        settings.isManualActive = { [weak self] in self?.coordinator.manualActive ?? false }
        settings.restorePhysical = { [weak self] in self?.coordinator.restorePhysical() }
        settings.openTour = { [weak self] in self?.tour.show() }
        coordinator.onChange = { [weak self] in self?.statusBar?.refresh() }

        // 心跳：看门狗据此判断主程序是否卡死（主线程定时器，卡住即停跳）
        Heartbeat.beat(Heartbeat.appURL)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Heartbeat.beat(Heartbeat.appURL) }
        installHotkey()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-about"), i + 1 < args.count {
            AboutPage.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            SettingsWindowController.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-tour-ui"), i + 2 < args.count {
            Tour.renderUI(imagesDir: URL(fileURLWithPath: args[i + 1]), to: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-tour"), i + 1 < args.count {
            Tour.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if args.contains("--selftest-settings") {
            selfTestSettings()
            return
        }
        if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
            let seconds = i + 2 < args.count ? (Double(args[i + 2]) ?? 6) : 6
            simulate(peers: args[i + 1], seconds: seconds)
            return
        }
        if let i = args.firstIndex(of: "--open-settings") {
            let pane = i + 1 < args.count ? SettingsPane(rawValue: args[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settings.show(pane: pane) }
        }
        if args.contains("--tour") {
            tour.show { NSApp.terminate(nil) }
            return
        }

        registerWatchdog()
        coordinator.start()

        let openDefaultPane: () -> Void = { [weak self] in
            self?.settings.show(pane: .controller)
        }
        if ConfigStore.shared.config.tourShown == true {
            // 常规启动留在菜单栏静默待命
        } else {
            tour.show(onDone: openDefaultPane)
        }
    }

    /// 退出前异步收尾（恢复物理屏、移除虚拟屏、还原布局）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        var done = false
        let finish: @MainActor @Sendable () -> Void = {
            guard !done else { return }
            done = true
            Log.info("退出 RustDisplay")
            NSApp.terminate(nil)
        }
        coordinator.shutdown(completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        return .terminateCancel
    }

    /// 看门狗以 LaunchAgent 形式安装（KeepAlive）：仅当用户在设置里开启时安装，否则确保已卸载
    private func registerWatchdog() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            Log.info("非 .app 运行，跳过看门狗安装（可手动运行 --watchdog）")
            return
        }
        if ConfigStore.shared.config.shouldRunWatchdog {
            WatchdogAgent.ensureInstalled()
        } else {
            WatchdogAgent.uninstall()
        }
    }

    /// 全局快捷键 ⌃⌥⌘9：立即恢复物理屏（Carbon 热键，无需任何权限）
    private func installHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { delegate.coordinator.restorePhysical() }
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x5244_5350), id: 1)  // 'RDSP'
        let err = RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(cmdKey | optionKey | controlKey), id,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.info(err == noErr ? "已注册快捷键 ⌃⌥⌘9" : "⚠️ 快捷键 ⌃⌥⌘9 注册失败 \(err)")
    }

    /// 自测：打开设置窗口，依次验证面板展开/收起、状态开关、预设与弹窗
    private func selfTestSettings() {
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let store = ConfigStore.shared
        var steps: [(String, () -> Void, () -> String?)] = []
        var results: [String] = []
        var heights: [String: CGFloat] = [:]
        func m() -> SettingsModel { settings.currentModel! }
        func h() -> CGFloat { settings.currentWindow?.frame.height ?? 0 }
        var openedTour = false, restored = false, toggledManual = false
        settings.openTour = { openedTour = true }
        settings.restorePhysical = { restored = true }
        settings.setManualActive = { _ in toggledManual = true }

        steps.append(("打开设置窗口", { self.settings.show() }, {
            heights["收起"] = h(); return h() > 200 ? nil : "窗口高度 \(h())" }))
        steps.append(("展开「虚拟屏与设备」", { m().toggle(.controller) }, {
            heights["设备"] = h(); return (m().expanded == .controller && h() > heights["收起"]! + 300) ? nil : "expanded=\(String(describing: m().expanded)) 高度=\(h())" }))
        steps.append(("再点一次收起", { m().toggle(.controller) }, {
            (m().expanded == nil && abs(h() - heights["收起"]!) < 2) ? nil : "高度=\(h())" }))
        steps.append(("展开「设置被控端」", { m().toggle(.controlled) }, {
            (m().expanded == .controlled && h() > heights["收起"]! + 150) ? nil : "高度=\(h())" }))
        steps.append(("「恢复兜底」在熄灭开关关闭时不可展开", { m().toggleDisablePhysical(false); m().toggle(.fallback) }, {
            (!m().fallbackAvailable && m().expanded == .controlled) ? nil : "expanded=\(String(describing: m().expanded))" }))
        steps.append(("关闭「自动拓展虚拟屏」", { m().toggleAutoVirtual(false) }, {
            (store.config.paused && !m().fallbackAvailable) ? nil : "paused=\(store.config.paused)" }))
        steps.append(("打开「自动拓展虚拟屏」", { m().toggleAutoVirtual(true) }, {
            !store.config.paused ? nil : "paused 仍为 true" }))
        steps.append(("切换「将虚拟屏设为主屏」", {
            m().toggleSetAsMain(true)
            let on = store.config.shouldSetAsMain
            m().toggleSetAsMain(false)
            _ = on
        }, { !store.config.shouldSetAsMain ? nil : "setAsMain 未还原" }))
        steps.append(("打开「远程时关闭除虚拟屏之外的所有屏幕」", { m().toggleDisablePhysical(true) }, {
            (store.config.shouldDisablePhysical && m().fallbackAvailable) ? nil : "disablePhysical=\(store.config.shouldDisablePhysical)" }))
        steps.append(("展开「恢复兜底」", { m().toggle(.fallback) }, {
            heights["找回"] = h(); return (m().expanded == .fallback && h() > heights["收起"]! + 300) ? nil : "高度=\(h())" }))
        steps.append(("关闭熄灭开关时自动收起「恢复兜底」", { m().toggleDisablePhysical(false) }, {
            (m().expanded == nil && !store.config.shouldDisablePhysical) ? nil : "expanded=\(String(describing: m().expanded))" }))
        if isAppBundle {
            steps.append(("打开后台守护", { m().toggleDisablePhysical(true); m().toggleWatchdog(true) }, {
                (store.config.shouldRunWatchdog && WatchdogAgent.isLoaded) ? nil : "已加载=\(WatchdogAgent.isLoaded)" }))
            steps.append(("后台守护开始值守", { RunLoop.main.run(until: Date().addingTimeInterval(4)); m().refresh() }, {
                m().watchdogRunning ? nil : "watchdogRunning=false" }))
            steps.append(("关闭后台守护", { m().toggleWatchdog(false); m().toggleDisablePhysical(false) }, {
                (!store.config.shouldRunWatchdog && !WatchdogAgent.isLoaded) ? nil : "仍已加载" }))
        } else {
            steps.append(("非 .app 跳过 launchctl 守护安装", { m().toggleWatchdog(true); m().toggleWatchdog(false) }, {
                !store.config.shouldRunWatchdog ? nil : "watchdogEnabled 未关闭" }))
        }
        steps.append(("「立即开启虚拟屏」按钮", { m().toggleManualVirtual() }, { toggledManual ? nil : "未调用" }))
        steps.append(("「立即恢复所有屏幕」按钮", { m().restorePhysical?() }, { restored ? nil : "未调用" }))
        steps.append(("「功能介绍」按钮", { m().openTour?() }, { openedTour ? nil : "未调用" }))
        steps.append(("「快速上手」按钮弹出说明", { m().quickStartShown = true }, {
            let shown = NSApp.windows.contains { $0.isVisible && $0.className.contains("Popover") }
            m().quickStartShown = false
            return shown ? nil : "没有弹出说明气泡"
        }))
        steps.append(("「关于 RustDesk 伴侣」按钮", { m().showAbout() }, {
            NSApp.windows.contains { $0.isVisible && $0 !== self.settings.currentWindow && $0.frame.width > 200 } ? nil : "没有出现关于面板" }))
        steps.append(("默认分辨率预设与按 IP 规则自动保存", {
            m().devices.applyPreset(ResolutionPreset.all[1])
            m().devices.addRule(peerIP: "100.64.0.10", name: "测试iPad")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        }, {
            (store.config.defaultWidth == 2560 && store.config.defaultHeight == 1440 && store.config.peerRules.count == 1 && m().savedHint)
                ? nil : "预设或规则未保存"
        }))

        var i = 0
        func next() {
            guard i < steps.count else {
                let passed = results.filter { $0.hasPrefix("✅") }.count
                Log.info("—— 设置窗口自测完成：\(passed)/\(steps.count) 通过")
                results.forEach { Log.info($0) }
                let failed = passed != steps.count
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(failed ? 1 : 0) }
                return
            }
            let (name, act, check) = steps[i]
            act()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let r = check()
                results.append(r == nil ? "✅ \(name)" : "❌ \(name)：\(r!)")
                i += 1
                next()
            }
        }
        next()
    }

    private func simulate(peers: String, seconds: Double) {
        coordinator.display.shouldSetAsMain = { ConfigStore.shared.config.shouldSetAsMain }
        coordinator.display.shouldDisablePhysical = { [weak self] in self?.coordinator.physicalDisableAllowed ?? false }
        coordinator.display.recoverIfNeeded()

        let list = peers.components(separatedBy: ">").filter { !$0.isEmpty }
        let first = list.first ?? "100.64.0.10"
        Log.info("模拟 RustDesk 连入：\(peers)，\(Int(seconds)) 秒后断开")
        coordinator.simulatedPeerIP = first
        coordinator.handleConnect(peerIP: nil)

        if list.count > 1 {
            let switchDelay = min(3.0, max(1.0, seconds / 2.0))
            DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay) { [weak self] in
                guard let self else { return }
                self.coordinator.simulatedPeerIP = list[1]
                self.coordinator.handleConnect(peerIP: nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.coordinator.simulatedPeerIP = nil
            self.coordinator.handleDisconnect()
            Log.info("模拟断开完成，等待虚拟屏清理")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
