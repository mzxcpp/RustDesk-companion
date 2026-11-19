// 设置窗口（上中下结构）
// 上：工作原理图「控制端 ⇢ 被控 Mac ⇢ 兜底」，点各自按钮向下展开对应面板（同一时间只展开一个）
// 中：立即开启虚拟屏 / 立即恢复所有屏幕 / 功能介绍 / 快速上手
// 下：关于 RustDesk 伴侣 / 完全退出（右对齐）
import AppKit
import ServiceManagement
import SwiftUI
import SystemSettingsKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case controller, controlled, fallback
    var id: String { rawValue }
}

final class SettingsModel: ObservableObject {
    // 注意：SwiftUI 的 @State 在仅有 Command Line Tools 时无法编译（宏插件缺失），界面状态统一放在 ObservableObject 里
    @Published var expanded: SettingsPane?
    @Published var autoVirtual: Bool
    @Published var setAsMain: Bool
    @Published var disablePhysical: Bool
    @Published var manualActive = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var watchdogEnabled: Bool
    @Published var watchdogRunning = Watchdog.isRunning
    @Published var physicalOff = PhysicalDisplays.pending != nil
    @Published var savedHint = false
    @Published var quickStartShown = false

    let devices = WizardModel()
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var setMainDisplay: ((Bool) -> Void)?
    var setManualActive: ((Bool) -> Void)?
    var isManualActive: (() -> Bool)?
    var restorePhysical: (() -> Void)?
    var openTour: (() -> Void)?
    private var timer: Timer?
    private let store = ConfigStore.shared

    init() {
        autoVirtual = !store.config.paused
        setAsMain = store.config.shouldSetAsMain
        disablePhysical = store.config.shouldDisablePhysical
        watchdogEnabled = store.config.shouldRunWatchdog
        devices.onSaved = { [weak self] in self?.devicesSaved() }
    }

    var fallbackAvailable: Bool { autoVirtual && disablePhysical }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let running = Watchdog.isRunning
        if running != watchdogRunning { watchdogRunning = running }
        let off = PhysicalDisplays.pending != nil
        if off != physicalOff { physicalOff = off }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
        if let manual = isManualActive?(), manual != manualActive { manualActive = manual }
        let auto = !store.config.paused
        if auto != autoVirtual { autoVirtual = auto }
        let main = store.config.shouldSetAsMain
        if main != setAsMain { setAsMain = main }
        let phys = store.config.shouldDisablePhysical
        if phys != disablePhysical { disablePhysical = phys }
    }

    /// 点同一个按钮再次收起；兜底面板只在开启软关闭后可展开
    func toggle(_ pane: SettingsPane) {
        if pane == .fallback && !fallbackAvailable { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            expanded = expanded == pane ? nil : pane
        }
    }

    /// 规则配置自动保存后：按新配置重新应用，并短暂显示「已自动保存」
    func devicesSaved() {
        onConfigChanged?()
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedHint = false }
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "开机启动没有设置成功：\(error.localizedDescription)。请先把本应用放进「应用程序」文件夹，再试一次。"
            Log.info("⚠️ 开机启动设置失败：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleAutoVirtual(_ on: Bool) {
        autoVirtual = on
        setPaused?(!on)
        Log.info("设置：自动拓展虚拟屏 → \(on ? "开" : "关")")
        if !fallbackAvailable && expanded == .fallback { withAnimation { expanded = nil } }
    }

    func toggleSetAsMain(_ on: Bool) {
        setAsMain = on
        setMainDisplay?(on)
        Log.info("设置：将虚拟屏设为主屏 → \(on ? "开" : "关")")
    }

    func toggleDisablePhysical(_ on: Bool) {
        disablePhysical = on
        setDisablePhysical?(on)
        Log.info("设置：自动软关闭物理屏 → \(on ? "开" : "关")")
        if !on && expanded == .fallback { withAnimation { expanded = nil } }
    }

    func toggleManualVirtual() {
        let next = !manualActive
        manualActive = next
        setManualActive?(next)
    }

    /// 只有在这里开启，看门狗才会安装为 LaunchAgent 并加载；关闭即卸载
    func toggleWatchdog(_ on: Bool) {
        watchdogEnabled = on
        store.config.watchdogEnabled = on
        Log.info("设置：看门狗 → \(on ? "开" : "关")")
        if Bundle.main.bundlePath.hasSuffix(".app") {
            if on { WatchdogAgent.ensureInstalled() } else { WatchdogAgent.uninstall() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @MainActor func showAbout() { AboutPage.show() }

    /// 完全退出：停掉本次登录中的看门狗（不卸载，下次打开 App 或重新登录时恢复），再退出主程序
    func quitCompletely() {
        Log.info("完全退出：停止看门狗并退出主程序")
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}

// MARK: - 快捷键示意图（⌃ ⌥ ⌘ 9 四个键）

private struct HotkeyCap: View {
    let symbol: String
    var name: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 2)
            .overlay(
                VStack(spacing: 2) {
                    Text(symbol).font(.system(size: name == nil ? 28 : 24, weight: .semibold))
                    if let name { Text(name).font(.system(size: 11, weight: .medium)) }
                }
                .foregroundStyle(.white)
            )
            .frame(width: name == nil ? 64 : 78, height: 64)
    }
}

struct HotkeyKeysView: View {
    var body: some View {
        HStack(spacing: 10) {
            HotkeyCap(symbol: "⌃", name: "control")
            plus
            HotkeyCap(symbol: "⌥", name: "option")
            plus
            HotkeyCap(symbol: "⌘", name: "command")
            plus
            HotkeyCap(symbol: "9")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("快捷键：同时按下 control、option、command 和 9")
    }

    private var plus: some View {
        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary)
    }
}

// MARK: - 面板

private struct Card<Content: View>: View {
    let icon: String
    let title: String
    let tag: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
                Text(title).font(.headline)
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - 工作原理图

private struct DashedConnector: View {
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 5))
                        p.addLine(to: CGPoint(x: w - 8, y: 5))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
                    Path { p in
                        p.move(to: CGPoint(x: w - 10, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 5))
                        p.addLine(to: CGPoint(x: w - 10, y: 10))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 10)
        }
        .padding(.top, 44)
        .frame(minWidth: 70, maxWidth: .infinity)
    }
}

private struct ControllerIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "ipad.landscape")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 112)
                .offset(x: -8, y: -14)
            Image(systemName: "iphone")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(height: 64)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .frame(width: 128, height: 128)
    }
}

private struct FlowNode<Icon: View>: View {
    let caption: String
    let buttonTitle: String
    var enabled = true
    var selected = false
    var hint: String? = nil
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 10) {
            icon()
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 128, height: 128)
            Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(enabled ? .primary : .secondary)
            Group {
                if selected {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.up") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.down") }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(!enabled)
            .help(hint ?? "")
        }
        .frame(width: 180)
    }
}

// MARK: - 展开面板

/// 被控制端：开机启动 / 自动拓展虚拟屏 / 设为主屏 / 自动软关闭物理屏
struct ControlledPanel: View {
    @ObservedObject var model: SettingsModel

    private func row(_ title: String, _ detail: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(!enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("被控端设置").font(.title3.bold())
            row("开机启动",
                "待机时内存占用约 60MB。",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
            if let err = model.loginError {
                Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            row("自动拓展虚拟屏",
                "RustDesk 远控连入时自动创建名为 \"RustDesk Companion\" 的高清虚拟屏；断开后自动移除并还原原有显示器布局。",
                isOn: Binding(get: { model.autoVirtual }, set: { model.toggleAutoVirtual($0) }))
            Divider()
            row("将虚拟屏设为主屏",
                "开启后连入时把虚拟屏设为主屏（Dock 与菜单栏会切过去）；关闭则保留 Mac 本机为主屏，仅在旁侧拓展出一块虚拟屏，可在 RustDesk 屏幕切换菜单中选用。",
                isOn: Binding(get: { model.setAsMain }, set: { model.toggleSetAsMain($0) }),
                enabled: model.autoVirtual)
            Divider()
            row("远程时关闭除虚拟屏之外的所有屏幕",
                "若不想在多屏间切换，或希望远程时所有窗口只留在虚拟屏中，请打开此功能；远程结束时自动点亮恢复。\n若担心恢复失败，可在「恢复兜底」里开启守护助手。",
                isOn: Binding(get: { model.disablePhysical }, set: { model.toggleDisablePhysical($0) }),
                enabled: model.autoVirtual)
            if !model.autoVirtual {
                Text("要先打开「自动拓展虚拟屏」。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 兜底选项：快捷键 + 看门狗
struct FallbackPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("恢复兜底").font(.title3.bold())
                Text("远程结束时，虚拟屏之外的屏幕会自动恢复。万一失败，请用下面的方法兜底找回。").foregroundStyle(.secondary)
            }

            Card(icon: "keyboard", title: "快捷键人肉兜底", tag: "随时可用") {
                Text("有人在本机前时、同时按下 **⌃ control + ⌥ option + ⌘ command + 9**，所有屏幕会立刻恢复，远程不受影响。")
                    .fixedSize(horizontal: false, vertical: true)
                HotkeyKeysView()
                Text("若没人在本机前，再次远程本机，点设置窗口的「立即恢复所有屏幕」，效果一样。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Card(icon: "shield.lefthalf.filled", title: "守护助手", tag: "可选") {
                Text("打开后，守护助手会在后台每 5 秒检查所有屏幕。遇到下面任一情况，它会自动把屏幕点亮：")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("• 本程序 崩溃或意外退出")
                    Text("• 本程序 卡住超过 10 秒没响应")
                    Text("• RustDesk 远程已经断开，但屏幕却没亮")
                }
                .font(.callout)
                Text("守护助手若自身意外退出，会在 5 秒内恢复。")
                    .font(.callout).foregroundStyle(.secondary)

                Divider()
                Text("需要你允许的事").font(.subheadline.bold())
                Text("守护助手打开后，macOS 会提示「RustDisplayWatchdog 已添加后台项目」，占用内存约 3MB。守护助手无需辅助功能等其他权限；关掉此处开关就会被彻底移除。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { model.watchdogEnabled }, set: { model.toggleWatchdog($0) })) {
                        Text("打开守护助手")
                    }
                    .toggleStyle(.switch)
                    if model.watchdogEnabled {
                        Label(model.watchdogRunning ? "正在值守" : "没有运行",
                              systemImage: model.watchdogRunning ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.watchdogRunning ? .green : .orange)
                        if !model.watchdogRunning {
                            Button("去系统设置里允许") { SystemSettings.open(.loginItems) }
                        }
                    }
                }
            }

            if !model.watchdogEnabled {
                Label("若本程序意外退出，远程结束时被关闭的屏幕不会自动恢复。",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 快速上手

private struct QuickStartView: View {
    private let steps = [
        "保持本应用在 Mac 菜单栏运行，无需配置辅助功能权限，会自动监测 RustDesk 远控连入。",
        "在「虚拟屏与设备」中确认默认分辨率（推荐 2560×1600 高清或与平板匹配的预设），也可按来源 IP 定制独立规则。",
        "使用平板或手机的 RustDesk 连入这台 Mac 后，系统会自动拓展出名为 \"RustDesk Companion\" 的虚拟屏幕。",
        "在 RustDesk 顶部/侧边菜单的屏幕切换中选中该虚拟屏即可无黑边显示；也可在「设置被控端」开启「将虚拟屏设为主屏」或「远程时只保留虚拟屏」。",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快速上手").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - 整体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 离屏渲染时展开内容不放进 ScrollView（便于检查完整排版）
    var forRender = false

    @ViewBuilder private var expandedContent: some View {
        switch model.expanded {
        case .controller:
            WizardView(model: model.devices, embedded: true, savedHint: model.savedHint)
                .frame(height: 500)
        case .controlled:
            ControlledPanel(model: model)
        case .fallback:
            if forRender {
                FallbackPanel(model: model)
            } else {
                ScrollView { FallbackPanel(model: model) }.frame(height: 520)
            }
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 上：工作原理图
            HStack(alignment: .top, spacing: 0) {
                FlowNode(caption: "用于远控的设备", buttonTitle: "虚拟屏与设备",
                         selected: model.expanded == .controller, action: { model.toggle(.controller) }) {
                    ControllerIcon()
                }
                DashedConnector(label: "使用 RustDesk 连入本机")
                FlowNode(caption: "本机", buttonTitle: "设置被控端",
                         selected: model.expanded == .controlled, action: { model.toggle(.controlled) }) {
                    Image(systemName: "desktopcomputer")
                }
                DashedConnector(label: "只保留虚拟屏时")
                FlowNode(caption: "万一物理屏没恢复", buttonTitle: "恢复兜底",
                         enabled: model.fallbackAvailable, selected: model.expanded == .fallback,
                         hint: model.fallbackAvailable ? nil : "先在「设置被控端」里打开「远程时关闭除虚拟屏之外的所有屏幕」",
                         action: { model.toggle(.fallback) }) {
                    Image(systemName: "lifepreserver")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            if model.expanded != nil {
                expandedContent
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // 中：常用操作
            HStack(spacing: 14) {
                Button { model.toggleManualVirtual() } label: {
                    Label(model.manualActive ? "关闭手动虚拟屏" : "立即开启虚拟屏",
                          systemImage: model.manualActive ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                }
                Button { model.restorePhysical?() } label: {
                    Label("立即恢复所有屏幕", systemImage: "display.2")
                }
                .disabled(!model.physicalOff)
                .help(model.physicalOff ? "也可以按 ⌃ control + ⌥ option + ⌘ command + 9" : "现在没有熄灭的屏幕")
                Button { model.openTour?() } label: { Label("功能介绍", systemImage: "sparkles") }
                Button { model.quickStartShown.toggle() } label: { Label("快速上手", systemImage: "list.number") }
                    .popover(isPresented: $model.quickStartShown, arrowEdge: .bottom) { QuickStartView() }
            }
            .controlSize(.large)
            .padding(.vertical, 16)

            Divider()

            // 下：关于 / 完全退出
            HStack(spacing: 10) {
                Spacer()
                Button("关于 RustDesk 伴侣") { model.showAbout() }
                Button("完全退出", role: .destructive) { model.quitCompletely() }
                    .help("关闭 RustDesk 伴侣，守护助手也会一起停下（下次打开时恢复）")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 900)
        .clipped()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    var currentModel: SettingsModel? { model }
    var currentWindow: NSWindow? { window }
    var openTour: (() -> Void)?
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var setMainDisplay: ((Bool) -> Void)?
    var setManualActive: ((Bool) -> Void)?
    var isManualActive: (() -> Bool)?
    var restorePhysical: (() -> Void)?

    /// - Parameter pane: 打开时展开的面板，nil 表示全部收起
    func show(pane: SettingsPane? = nil) {
        if let window, let model {
            if let pane, model.expanded != pane { model.toggle(pane) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel()
        model.expanded = (pane == .fallback && !model.fallbackAvailable) ? nil : pane
        model.onConfigChanged = onConfigChanged
        model.setDisablePhysical = setDisablePhysical
        model.setPaused = setPaused
        model.setMainDisplay = setMainDisplay
        model.setManualActive = setManualActive
        model.isManualActive = isManualActive
        model.restorePhysical = restorePhysical
        model.openTour = openTour
        model.start()
        self.model = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "RustDesk 伴侣 · 设置"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model?.stop()
            self?.model = nil
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染各状态为 PNG（--render-settings <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, SettingsPane?, Bool, Bool)] = [
            ("collapsed-physical-off", nil, false, false),
            ("collapsed-physical-on", nil, true, false),
            ("controller", .controller, false, false),
            ("controlled", .controlled, true, false),
            ("fallback", .fallback, true, true),
        ]
        for (name, pane, physical, watchdog) in cases {
            let model = SettingsModel()
            model.autoVirtual = true
            model.disablePhysical = physical
            model.watchdogEnabled = watchdog
            model.watchdogRunning = false
            model.expanded = pane
            let view = NSHostingView(rootView: SettingsView(model: model, forRender: true))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(name).png"))
            }
        }
    }
}
