// 「关于」窗口（纯 SwiftUI + AppKit 本地实现，无外部私有依赖）
import AppKit
import SwiftUI

private struct CreditEntry: Identifiable {
    let id = UUID()
    let name: String
    let author: String
    let license: String
    let usage: String
    let url: String
}

private struct AboutView: View {
    private let credits: [CreditEntry] = [
        .init(name: "UUyc-companion", author: "aoyamashou", license: "MIT", usage: "原项目：核心虚拟屏、状态机与界面设计", url: "https://github.com/aoyamashou/UUyc-companion"),
        .init(name: "FreeDisplay", author: "huberdf", license: "MIT", usage: "CGVirtualDisplay 接口声明", url: "https://github.com/huberdf/FreeDisplay"),
        .init(name: "PermissionFlow / SystemSettingsKit", author: "jaywcjlove", license: "MIT", usage: "系统设置跳转", url: "https://github.com/jaywcjlove/PermissionFlow"),
        .init(name: "TourKit", author: "rampatra", license: "MIT", usage: "首次启动功能导览", url: "https://github.com/rampatra/TourKit"),
    ]

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "版本 \(short)"
    }

    private func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                if let img = appIcon() {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 68, height: 68)
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 46))
                        .foregroundStyle(.tint)
                        .frame(width: 68, height: 68)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("RustDesk 伴侣").font(.title2.bold())
                    Text("RustDesk Companion · \(versionText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("为 Mac 版 RustDesk 自动拓展与还原虚拟屏幕")
                        .font(.callout)
                }
                Spacer()
            }

            Text("当平板、手机或其它电脑通过 RustDesk 远控连入本机时，自动创建指定分辨率的高清（HiDPI）虚拟屏幕；远控断开后自动移除虚拟屏并还原物理显示器排列。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("项目来源与贡献说明").font(.headline)
                Text("本软件基于并派生自 aoyamashou 开源的 UUyc-companion（UU远程伴侣，MIT 协议）。核心 CGVirtualDisplay 虚拟屏创建、WindowServer 防崩溃逐步收敛状态机、物理屏软关闭、⌃⌥⌘9 快捷键与守护进程兜底机制、界面框架及图标素材均源自原作者。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("本仓库（mzxcpp/RustDesk-companion）的贡献仅限于将远控检测与配置逻辑从 UU远程 迁移适配至 RustDesk（免辅助功能权限的本地日志与 Darwin libproc 会话检测、默认纯扩展虚拟屏模式、分辨率预设与按来源 IP 规则，以及离线本地关于页）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link("原项目：aoyamashou/UUyc-companion",
                         destination: URL(string: "https://github.com/aoyamashou/UUyc-companion")!)
                    Link("本仓库：mzxcpp/RustDesk-companion",
                         destination: URL(string: "https://github.com/mzxcpp/RustDesk-companion")!)
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("致谢与开源组件").font(.headline)
                ForEach(credits) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.name).font(.callout.weight(.semibold))
                        Text("(\(item.author) · \(item.license))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.usage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Text("免责声明：本应用与 RustDesk 及其开发团队没有任何直接、间接或连带关系，仅作为 Mac 被控端的本地辅助工具使用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 540)
    }
}

@MainActor
enum AboutPage {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.title = "关于 RustDesk 伴侣"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func render(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let view = NSHostingView(rootView: AboutView())
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
