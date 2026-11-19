// 菜单栏：状态 / 手动开关虚拟屏 / 设为主屏 / 远程时只保留虚拟屏 / 设置 / 完全退出
import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPane?) -> Void
    private let store = ConfigStore.shared

    init(coordinator: Coordinator, openSettings: @escaping (SettingsPane?) -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    private static let menuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    func refresh() {
        let icon = StatusBarController.menuBarIcon
        icon.accessibilityDescription = "RustDesk 伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused && !coordinator.manualActive
        item.button?.toolTip = "RustDesk 伴侣：\(coordinator.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let manual = action(coordinator.manualActive ? "关闭手动虚拟屏" : "立即开启虚拟屏（测试/扩展）", #selector(toggleManual))
        manual.state = coordinator.manualActive ? .on : .off
        menu.addItem(manual)

        let autoItem = action("RustDesk 连入时自动创建虚拟屏", #selector(toggleAuto))
        autoItem.state = !store.config.paused ? .on : .off
        menu.addItem(autoItem)

        let mainItem = action("将虚拟屏设为主屏", #selector(toggleSetAsMain))
        mainItem.state = store.config.shouldSetAsMain ? .on : .off
        menu.addItem(mainItem)

        let physical = action("远程时只保留虚拟屏", #selector(toggleDisablePhysical))
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        menu.addItem(physical)

        if coordinator.display.physicalOff {
            menu.addItem(.separator())
            menu.addItem(action("立即恢复所有物理屏 (⌃⌥⌘9)", #selector(restorePhysical)))
        }

        menu.addItem(.separator())
        menu.addItem(action("设置…", #selector(reconfigure), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("完全退出", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func toggleManual() { coordinator.setManualActive(!coordinator.manualActive) }
    @objc private func toggleAuto() { coordinator.setPaused(!store.config.paused) }
    @objc private func toggleSetAsMain() { coordinator.setAsMain(!store.config.shouldSetAsMain) }
    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }
    @objc private func restorePhysical() { coordinator.restorePhysical() }
    @objc private func reconfigure() { openSettings(nil) }

    @objc private func quit() {
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}
