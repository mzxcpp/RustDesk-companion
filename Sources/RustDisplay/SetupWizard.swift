// 虚拟屏分辨率与按来源 IP 自定义设备规则面板（改动自动保存）
import AppKit
import SwiftUI

final class WizardModel: ObservableObject {
    @Published var defaultWidth: Int
    @Published var defaultHeight: Int
    @Published var defaultHiDPI: Bool
    @Published var useDefaultForUnknownPeers: Bool
    @Published var rules: [PeerRule]
    @Published var recentIPs: [String] = []
    @Published var message: String?

    var onSaved: (() -> Void)?

    private let store = ConfigStore.shared
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() {
        let cfg = ConfigStore.shared.config
        defaultWidth = cfg.defaultWidth
        defaultHeight = cfg.defaultHeight
        defaultHiDPI = cfg.defaultHiDPI
        useDefaultForUnknownPeers = cfg.useDefaultForUnknownPeers
        rules = cfg.peerRules
        refreshRecentIPs()
    }

    func ruleBinding(for id: UUID) -> Binding<PeerRule> {
        Binding(
            get: { [weak self] in
                self?.rules.first { $0.id == id } ?? PeerRule(id: id, peerIP: "", name: "")
            },
            set: { [weak self] updated in
                guard let self, let idx = self.rules.firstIndex(where: { $0.id == id }) else { return }
                self.rules[idx] = updated
            }
        )
    }

    func refreshRecentIPs() {
        if ProcessInfo.processInfo.environment["RUSTDISPLAY_DEMO_RENDER"] == "1" {
            recentIPs = ["100.64.0.10", "192.168.1.50"]
            message = "已从 RustDesk 日志读取到 2 个近期连入来源，可按需为其指定独立分辨率。"
            return
        }
        let scanned = RustDeskProbe.scanRecentPeerIPs()
        recentIPs = scanned
        if scanned.isEmpty {
            message = "未在 RustDesk 日志中发现历史连接，连入一次后可自动识别来源 IP；默认虚拟屏无需配置 IP 即可生效。"
        } else {
            message = "已从 RustDesk 日志读取到 \(scanned.count) 个近期连入来源，可按需为其指定独立分辨率。"
        }
    }

    func applyPreset(_ preset: ResolutionPreset) {
        defaultWidth = preset.width
        defaultHeight = preset.height
        defaultHiDPI = preset.hiDPI
        scheduleSave(immediate: true)
    }

    func addRule(peerIP: String = "", name: String = "") {
        let cleanIP = peerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIP.isEmpty, rules.contains(where: { $0.peerIP.trimmingCharacters(in: .whitespacesAndNewlines) == cleanIP }) {
            return
        }
        rules.append(PeerRule(
            peerIP: cleanIP,
            name: name.isEmpty ? (cleanIP.isEmpty ? "新设备" : "设备 \(cleanIP)") : name,
            useVirtualDisplay: true,
            width: defaultWidth,
            height: defaultHeight,
            hiDPI: defaultHiDPI
        ))
        scheduleSave(immediate: true)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        scheduleSave(immediate: true)
    }

    func scheduleSave(immediate: Bool = false) {
        guard !loading else { return }
        saveWork?.cancel()
        if immediate {
            save()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func save() {
        saveWork?.cancel()
        guard DisplayProfile.validSize.contains(defaultWidth),
              DisplayProfile.validSize.contains(defaultHeight) else { return }
        guard rules.allSatisfy({ !$0.useVirtualDisplay || $0.hasValidSize }) else { return }
        var cfg = store.config
        cfg.defaultWidth = defaultWidth
        cfg.defaultHeight = defaultHeight
        cfg.defaultHiDPI = defaultHiDPI
        cfg.useDefaultForUnknownPeers = useDefaultForUnknownPeers
        cfg.peerRules = rules
        store.config = cfg
        onSaved?()
    }
}

struct PeerRuleRow: View {
    @Binding var rule: PeerRule
    let onChanged: () -> Void
    let onDelete: () -> Void

    private func intBinding(_ key: WritableKeyPath<PeerRule, Int>) -> Binding<Int?> {
        Binding(
            get: { rule[keyPath: key] == 0 ? nil : rule[keyPath: key] },
            set: { rule[keyPath: key] = $0 ?? 0; onChanged() }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("来源 IP (如 100.64.0.10)", text: Binding(
                get: { rule.peerIP },
                set: { rule.peerIP = $0; onChanged() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)

            TextField("设备备注", text: Binding(
                get: { rule.name },
                set: { rule.name = $0; onChanged() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)

            Picker("", selection: Binding(
                get: { rule.useVirtualDisplay },
                set: { rule.useVirtualDisplay = $0; onChanged() }
            )) {
                Text("不创建").tag(false)
                Text("自定义分辨率").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 155)

            if rule.useVirtualDisplay {
                TextField("宽", value: intBinding(\.width), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                Text("×")
                TextField("高", value: intBinding(\.height), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                Toggle("HiDPI", isOn: Binding(
                    get: { rule.hiDPI },
                    set: { rule.hiDPI = $0; onChanged() }
                ))
            } else {
                Text("保持原样，不创建虚拟屏")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除此规则")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    var embedded = false
    var savedHint = false

    private func defaultIntBinding(_ key: ReferenceWritableKeyPath<WizardModel, Int>) -> Binding<Int?> {
        Binding(
            get: { model[keyPath: key] == 0 ? nil : model[keyPath: key] },
            set: { model[keyPath: key] = $0 ?? 0; model.scheduleSave() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("虚拟屏分辨率与设备规则").font(.title2.bold())
                Spacer()
                if savedHint {
                    Label("已自动保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("刷新近期连入 IP") { model.refreshRecentIPs() }
            }

            // 默认虚拟屏配置卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("默认虚拟屏（所有 RustDesk 连入开箱即用）", systemImage: "rectangle.on.rectangle")
                        .font(.headline)
                    Spacer()
                    Toggle("对未单独配置的设备启用", isOn: Binding(
                        get: { model.useDefaultForUnknownPeers },
                        set: { model.useDefaultForUnknownPeers = $0; model.scheduleSave(immediate: true) }
                    ))
                    .toggleStyle(.switch)
                }

                HStack(spacing: 10) {
                    Text("分辨率：").foregroundStyle(.secondary)
                    TextField("宽", value: defaultIntBinding(\.defaultWidth), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("高", value: defaultIntBinding(\.defaultHeight), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                    Text("像素").foregroundStyle(.secondary)
                    Toggle("高清（HiDPI）", isOn: Binding(
                        get: { model.defaultHiDPI },
                        set: { model.defaultHiDPI = $0; model.scheduleSave(immediate: true) }
                    ))
                    .padding(.leading, 8)
                    Spacer()
                }
                .disabled(!model.useDefaultForUnknownPeers)

                // 常用预设按钮
                HStack(spacing: 8) {
                    Text("常用预设：").font(.caption).foregroundStyle(.secondary)
                    ForEach(ResolutionPreset.all) { preset in
                        Button(preset.title) { model.applyPreset(preset) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                .disabled(!model.useDefaultForUnknownPeers)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))

            // 近期连入 IP 快捷添加
            if !model.recentIPs.isEmpty {
                HStack(spacing: 8) {
                    Text("近期连入来源：").font(.callout).foregroundStyle(.secondary)
                    ForEach(model.recentIPs.prefix(4), id: \.self) { ip in
                        let exists = model.rules.contains { $0.peerIP.trimmingCharacters(in: .whitespacesAndNewlines) == ip }
                        Button {
                            model.addRule(peerIP: ip)
                        } label: {
                            Label(ip, systemImage: exists ? "checkmark" : "plus.circle")
                        }
                        .controlSize(.small)
                        .disabled(exists)
                    }
                    Spacer()
                }
            } else if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("按来源 IP 定制设备规则（可选）").font(.headline)
                Text("如 Tailscale / 局域网固定 IP").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addRule() } label: {
                    Label("手动添加规则", systemImage: "plus")
                }
                .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.rules.isEmpty {
                        Text("暂无独立规则。当前所有 RustDesk 连入均使用上方「默认虚拟屏」配置。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(model.rules) { rule in
                            PeerRuleRow(
                                rule: model.ruleBinding(for: rule.id),
                                onChanged: { model.scheduleSave() },
                                onDelete: { model.removeRule(id: rule.id) }
                            )
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 150)
        }
        .padding(embedded ? 24 : 20)
        .frame(minWidth: embedded ? nil : 860, minHeight: 460)
    }
}
