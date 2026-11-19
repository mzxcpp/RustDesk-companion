// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 继承自 UUyc-companion 经实测验证的 WindowServer 防崩溃状态机：
//   - 一次只做一步拓扑变化，每步之后等待系统稳定（settle）再做下一步
//   - 虚拟屏释放前必须已上线且存活 ≥ 2.5 秒（否则可能让 WindowServer 显示配置卡死）
//   - GUI 主线程不能调 CGCompleteDisplayConfiguration（统一放 cgQueue）
//   - 物理屏是否被禁用以磁盘记录为准（看门狗可能在别的进程里已恢复）
// 针对 RustDesk 的扩展：
//   - 支持「扩展屏模式」（shouldSetAsMain = false）与「设为主屏模式」（shouldSetAsMain = true）
//   - 保持 Apple 原生默认 CGVirtualDisplayDescriptor 参数，同时将 HiDPI 逻辑宽高对齐为偶数
//   - 排除 PhysicalDisplays.pending 避免对正在关闭中的物理屏重复调用 CGSConfigureDisplayEnabled (CGError=1001)
//   - 通过 CGDisplayRegisterReconfigurationCallback 为延迟上线的外接物理屏补做关闭
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

final class DisplayManager {
    static let vendorID: UInt32 = 0x5244  // 'RD'

    // 目标状态
    private var desired: DisplayProfile?
    private var shutdownCompletion: (() -> Void)?
    /// 是否将虚拟屏设为主屏（关闭时仅作为扩展屏附加，不移动菜单栏和 Dock）
    var shouldSetAsMain: () -> Bool = { false }
    /// 是否应禁用物理屏（由 Coordinator 按设置决定）
    var shouldDisablePhysical: () -> Bool = { false }
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false

    // 实际状态
    private var vd: CGVirtualDisplay?
    private(set) var current: DisplayProfile?
    private var mainSet = false
    /// 换设备时的旧屏，等新屏上线后释放
    private var retiring: [CGVirtualDisplay] = []
    /// 配置失败的虚拟屏，稳定后再释放（立即释放曾触发 WindowServer 崩溃）
    private var broken: [CGVirtualDisplay] = []
    /// 同一配置创建失败后不再重试，直到目标变化
    private var failedCfg: DisplayProfile?
    /// 建屏前各物理屏的原点，用于还原
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]

    // 执行器
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var releaseWaitStart: Date?
    /// WindowServer 显示配置无响应（事务超时）：停止建屏/删屏/改布局
    private(set) var wedged = false
    static let minLifetime: TimeInterval = 2.5
    private let cgQueue = DispatchQueue(label: "rustdisplay.display-config", qos: .userInitiated)
    private var reconfigWork: DispatchWorkItem?
    private var reconfigRegistered = false

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.handleSystemDisplayReconfigured()
        }
    }

    init() {
        let err = CGDisplayRegisterReconfigurationCallback(Self.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        reconfigRegistered = (err == .success)
    }

    deinit {
        reconfigWork?.cancel()
        if reconfigRegistered {
            CGDisplayRemoveReconfigurationCallback(Self.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var isActive: Bool { vd != nil }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    private static func same(_ a: DisplayProfile?, _ b: DisplayProfile?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.width == b.width && a.height == b.height && a.hiDPI == b.hiDPI
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DisplayProfile) -> Bool { DisplayManager.same(desired, cfg) && vd != nil }

    // MARK: - 对外接口：只改目标状态

    func create(_ cfg: DisplayProfile) {
        if !DisplayManager.same(desired, cfg) { failedCfg = nil }
        desired = cfg
        kick()
    }

    func remove(completion: (() -> Void)? = nil) {
        desired = nil
        failedCfg = nil
        physicalOverride = false
        if let completion { shutdownCompletion = completion }
        kick()
    }

    func reevaluateTopology() { kick() }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        kick()
    }

    /// 启动时：读回上次未收尾的布局记录；残留的物理屏禁用记录由执行器按「目标=无」自动恢复
    func recoverIfNeeded() {
        if let data = try? Data(contentsOf: DisplayManager.markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
            for (k, v) in dict where v.count == 2 {
                if let id = UInt32(k) { savedOrigins[id] = CGPoint(x: v[0], y: v[1]) }
            }
        }
        if !savedOrigins.isEmpty || physicalOff {
            Log.info("发现上次异常退出的残留状态，先恢复物理屏与显示器布局")
            recovering = true
        }
        kick()
    }

    // MARK: - 系统显示器重配置监听（捕获延迟唤醒上线的外接显示器）

    private func handleSystemDisplayReconfigured() {
        reconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.busy, !self.wedged, self.desired != nil,
                  self.shouldDisablePhysical(), !self.physicalOverride else { return }
            let alreadyDisabled = Set(PhysicalDisplays.pending ?? [])
            let stray = DisplayManager.onlineDisplays().filter {
                !DisplayManager.isVirtual($0) && !alreadyDisabled.contains($0)
            }
            if !stray.isEmpty {
                Log.info("检测到物理屏延迟上线 \(stray)，补做关闭")
                self.kick()
            }
        }
        reconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - 执行器

    private func kick() {
        guard !busy else { return }
        step()
    }

    /// 完成一步后等待 settle 秒再评估下一步
    private func finish(settle: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.step()
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, _ work: @escaping () -> CGError) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                if err == .cannotComplete || err.rawValue == 1014 { self.enterWedged(err) }
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError) {
        guard !wedged else { return }
        wedged = true
        Log.info("⛔️ WindowServer 显示配置无响应（CGError=\(err.rawValue)），停止一切显示操作；请注销或重启 Mac 恢复")
    }

    /// 释放前确认每块屏已上线且存活足够久；最多等 8 秒
    private func readyToRelease(_ displays: [CGVirtualDisplay]) -> Bool {
        let online = Set(DisplayManager.onlineDisplays())
        let young = displays.contains { d in
            !online.contains(d.displayID) || Date().timeIntervalSince(bornAt[d.displayID] ?? .distantPast) < DisplayManager.minLifetime
        }
        guard young else { releaseWaitStart = nil; return true }
        let start = releaseWaitStart ?? Date()
        releaseWaitStart = start
        if Date().timeIntervalSince(start) > 8 { releaseWaitStart = nil; return true }
        return false
    }

    private func step() {
        guard !busy else { return }
        if wedged {
            if physicalOff { return runCG(settle: 3) { PhysicalDisplays.restore(reason: "保护状态") ? .success : .failure } }
            if let done = shutdownCompletion { shutdownCompletion = nil; done() }
            return
        }

        // 1. 配置失败的屏：稳定后释放
        if !broken.isEmpty {
            guard readyToRelease(broken) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&broken)
            return finish(settle: 1.5)
        }

        guard let want = recovering ? nil : desired else {
            // 目标=无：恢复物理屏 → 释放虚拟屏 → 还原布局
            if physicalOff {
                busy = true
                cgQueue.async {
                    let ok = PhysicalDisplays.restore(reason: "远程结束")
                    DispatchQueue.main.async { self.finish(settle: ok ? 0.4 : 1.2) }
                }
                return
            }
            if vd != nil || !retiring.isEmpty {
                guard readyToRelease(retiring + [vd].compactMap { $0 }) else { busy = true; return finish(settle: 0.5) }
                busy = true
                var all = retiring + [vd].compactMap { $0 }
                retiring = []
                vd = nil
                current = nil
                mainSet = false
                release(&all)
                return finish(settle: 0.5)
            }
            if !savedOrigins.isEmpty {
                let origins = savedOrigins
                savedOrigins = [:]
                try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                return runCG(settle: 0.5) { DisplayManager.restoreOrigins(origins) }
            }
            if recovering {
                recovering = false
                Log.info("残留状态已恢复")
                if desired != nil { return step() }
            }
            if let done = shutdownCompletion {
                shutdownCompletion = nil
                done()
            }
            return
        }

        // 目标=某规格的虚拟屏
        if vd == nil || !DisplayManager.same(current, want) {
            guard !DisplayManager.same(failedCfg, want) else { return }
            busy = true
            if let old = vd { retiring.append(old) }
            vd = nil
            current = nil
            mainSet = false
            waitOnlineTries = 0
            if !createDisplay(want) { failedCfg = want }
            return finish(settle: 0.15)
        }

        let wantOff = shouldDisablePhysical() && !physicalOverride
        // 当即将关闭所有物理屏时，虚拟屏成为唯一在线屏会自动置为 (0,0) 主屏，跳过多余的 4 屏原点重排
        let wantMain = shouldSetAsMain() && !wantOff

        if let id = vd?.displayID {
            let online = DisplayManager.onlineDisplays()
            if !online.contains(id) {
                waitOnlineTries += 1
                if waitOnlineTries > 35 { Log.info("⚠️ 虚拟屏 5 秒内未上线"); mainSet = true }
                busy = true
                return finish(settle: 0.15)
            }

            if !wantOff, physicalOff {
                busy = true
                cgQueue.async {
                    let ok = PhysicalDisplays.restore(reason: "手动恢复")
                    DispatchQueue.main.async { self.finish(settle: ok ? 0.5 : 1.2) }
                }
                return
            }

            if wantMain && !mainSet {
                if savedOrigins.isEmpty {
                    savedOrigins = Dictionary(uniqueKeysWithValues: online.filter { !DisplayManager.isVirtual($0) }
                        .map { ($0, CGDisplayBounds($0).origin) })
                }
                writeMarker()
                mainSet = true
                return runCG(settle: 0.5) {
                    let err = applyDisplayConfig { cfg in
                        let t = CGDisplayBounds(id).origin
                        for d in online {
                            let o = CGDisplayBounds(d).origin
                            CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                        }
                    }
                    Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                    return err
                }
            } else if !wantMain && !physicalOff && !savedOrigins.isEmpty {
                // 用户切回「纯扩展屏模式」或中途恢复物理屏：还原物理屏为主屏
                let origins = savedOrigins
                savedOrigins = [:]
                mainSet = false
                try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                return runCG(settle: 0.5) { DisplayManager.restoreOrigins(origins) }
            }
        }

        if !retiring.isEmpty {
            guard readyToRelease(retiring) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&retiring)
            return finish(settle: 1.5)
        }

        if wantOff, let id = vd?.displayID {
            let alreadyDisabled = Set(PhysicalDisplays.pending ?? [])
            let toDisable = DisplayManager.onlineDisplays().filter {
                !DisplayManager.isVirtual($0) && !alreadyDisabled.contains($0)
            }
            if !toDisable.isEmpty {
                var added = false
                for pid in toDisable where savedOrigins[pid] == nil {
                    savedOrigins[pid] = CGDisplayBounds(pid).origin
                    added = true
                }
                if added { writeMarker() }
                return runCG(settle: 1.0) {
                    let err = PhysicalDisplays.disable(toDisable)
                    Log.info(err == .success ? "✅ 已关闭物理屏 \(toDisable)，只保留虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
                    return err
                }
            }
        }
    }

    // MARK: - 单步操作

    private func createDisplay(_ cfg: DisplayProfile) -> Bool {
        // HiDPI 下将逻辑宽高对齐为偶数，使像素宽高为 4 的倍数；其余 Descriptor 参数保留 Apple 原生默认值
        let mw: Int
        let mh: Int
        let pixelW: Int
        let pixelH: Int
        if cfg.hiDPI {
            mw = max(160, ((cfg.width + 1) / 2) & ~1)
            mh = max(160, ((cfg.height + 1) / 2) & ~1)
            pixelW = mw * 2
            pixelH = mh * 2
        } else {
            mw = max(320, cfg.width & ~1)
            mh = max(320, cfg.height & ~1)
            pixelW = mw
            pixelH = mh
        }

        let desc = CGVirtualDisplayDescriptor()
        desc.name = "RustDesk Companion · \(cfg.label)"
        desc.maxPixelsWide = UInt32(pixelW)
        desc.maxPixelsHigh = UInt32(pixelH)
        desc.sizeInMillimeters = CGSize(width: Double(pixelW) / 220 * 25.4, height: Double(pixelH) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = 0x0001
        // 每次随机序列号：与残留虚拟屏同序列号时 CGVirtualDisplay 会返回 nil
        desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        if let mode = CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60) {
            settings.modes = [mode]
        }
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败，稳定后释放")
            bornAt[display.displayID] = Date()
            broken.append(display)
            return false
        }
        vd = display
        current = cfg
        bornAt[display.displayID] = Date()
        let actualLabel = "\(pixelW)×\(pixelH)\(cfg.hiDPI ? " 高清" : "")"
        Log.info("✅ 已创建虚拟屏 #\(display.displayID) \(cfg.label) \(actualLabel)")
        return true
    }

    private func release(_ displays: inout [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        let ids = displays.map { "#\($0.displayID)" }.joined(separator: " ")
        autoreleasepool { displays.removeAll() }
        Log.info("✅ 已移除虚拟屏 \(ids)")
    }

    private static func restoreOrigins(_ origins: [CGDirectDisplayID: CGPoint]) -> CGError {
        let online = Set(onlineDisplays())
        let targets = origins.filter { online.contains($0.key) }
        guard !targets.isEmpty else { return .success }
        let dirty = targets.filter { id, want in
            let cur = CGDisplayBounds(id).origin
            return abs(cur.x - want.x) > 1 || abs(cur.y - want.y) > 1
        }
        if dirty.isEmpty {
            Log.info("✅ 显示器布局已就位，无需额外重排")
            return .success
        }
        let err = applyDisplayConfig { cfg in
            for (id, o) in targets { CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y)) }
        }
        Log.info(err == .success ? "✅ 已还原显示器布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
        return err
    }

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedOrigins.map { ("\($0.key)", [$0.value.x, $0.value.y]) })
        try? JSONSerialization.data(withJSONObject: dict).write(to: DisplayManager.markerURL, options: .atomic)
    }
}
