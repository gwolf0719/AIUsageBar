import AppKit
import ServiceManagement
import SwiftUI

// 點狀態列彈出的儀表板（取代原本的文字選單）。

@MainActor
final class DashboardModel: ObservableObject {
    @Published var states: [String: ProviderState] = [:]
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var now = Date()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var book = AccountBook()

    var onRefresh: () -> Void = {}
    var onLogin: (Provider) -> Void = { _ in }
    var onSwitch: (Provider, String) -> Void = { _, _ in }
    var onRemove: (Provider, String) -> Void = { _, _ in }
    var onOpenStore: () -> Void = {}

    func setLaunchAtLogin(_ on: Bool) {
        setLoginItem(on)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 樣式

enum Theme {
    static func brand(_ id: String) -> Color {
        switch id {
        case "codex": return Color(red: 0.06, green: 0.64, blue: 0.50)
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        default: return Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }

    /// 依剩餘比例上色：充足綠、偏低黃、不足紅。
    static func level(_ remaining: Double) -> Color {
        if remaining < 20 { return Color(red: 0.90, green: 0.27, blue: 0.24) }
        if remaining < 50 { return Color(red: 0.93, green: 0.62, blue: 0.13) }
        return Color(red: 0.20, green: 0.70, blue: 0.40)
    }

    /// 圖示本身的顏色：OpenAI 標誌是單色，跟著文字色走；其他用品牌色。
    static func mark(_ id: String) -> Color { id == "codex" ? .primary : brand(id) }

    static let card = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)
}

/// 品牌圖示（Resources/<id>.svg，向量、當成範本圖上色）。
@MainActor
func brandImage(_ id: String) -> NSImage? {
    if let cached = brandImageCache[id] { return cached }
    guard let url = Bundle.main.url(forResource: id, withExtension: "svg"), let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = true
    brandImageCache[id] = image
    return image
}
@MainActor private var brandImageCache: [String: NSImage] = [:]

struct BrandIcon: View {
    let id: String
    let fallback: String
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.brand(id).opacity(0.13))
            .frame(width: size, height: size)
            .overlay(Group {
                if let image = brandImage(id) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundColor(Theme.mark(id)).padding(size * 0.2)
                } else {
                    Text(fallback).font(.system(size: size * 0.33, weight: .bold, design: .rounded)).foregroundColor(Theme.brand(id))
                }
            })
    }
}

/// 「今天 16:03」「明天 09:00」「11/22（日）14:15」
func resetLabel(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_TW")
    f.dateFormat = "HH:mm"
    let clock = f.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "今天 \(clock)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return "明天 \(clock)" }
    f.dateFormat = "M/d（EEEEE）HH:mm"
    return f.string(from: date)
}

// MARK: - 主畫面

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                ForEach(allProviders.indices, id: \.self) { i in
                    let p = allProviders[i]
                    ProviderCard(provider: p, state: model.states[p.id] ?? ProviderState(), now: model.now,
                                 others: model.book.others(p.id),
                                 onLogin: { model.onLogin(p) },
                                 onSwitch: { model.onSwitch(p, $0) },
                                 onRemove: { model.onRemove(p, $0) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 用量").font(.system(size: 15, weight: .semibold))
                Text(updatedText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.onRefresh) {
                Group {
                    if model.refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .help("立即更新（⌘R）")
            .disabled(model.refreshing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var updatedText: String {
        if model.refreshing { return "更新中…" }
        guard let last = model.lastRefresh else { return "尚未更新" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "更新於 \(f.string(from: last))・每 5 分鐘自動更新"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("登入時自動啟動", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            FooterButton(title: "紀錄", systemImage: "folder", action: model.onOpenStore)
            FooterButton(title: "結束", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 每家一張卡

struct ProviderCard: View {
    let provider: Provider
    let state: ProviderState
    let now: Date
    var others: [AccountRecord] = []
    let onLogin: () -> Void
    var onSwitch: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }

    private var switchable: Bool { provider is CredentialSource }

    private var brand: Color { Theme.brand(provider.id) }
    private var name: String { provider.title.components(separatedBy: "（").first ?? provider.title }
    private var source: String {
        provider.title.components(separatedBy: "（").dropFirst().first?.replacingOccurrences(of: "）", with: "") ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            if let snapshot = state.snapshot, let head = snapshot.headline {
                summary(snapshot, head)
                if snapshot.windows.count == 1 {
                    // 只有一個額度：大數字已經說完了，只補一條進度條，不重複列出。
                    UsageBar(fraction: head.remaining / 100, color: Theme.level(head.remaining))
                } else {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    VStack(spacing: 10) {
                        ForEach(snapshot.windows.indices, id: \.self) { i in
                            WindowRow(window: snapshot.windows[i], now: now)
                        }
                    }
                }
            } else if !state.needsLogin {
                Text(state.error == nil ? "讀取中…" : "目前沒有資料")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = state.error { notice(error) }
            if !others.isEmpty { otherAccounts }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .opacity(state.error != nil && state.snapshot != nil && !state.needsLogin ? 0.85 : 1)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            BrandIcon(id: provider.id, fallback: provider.short)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(state.snapshot?.account ?? source)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(source)
            }
            Spacer(minLength: 8)
            if let plan = state.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(brand.opacity(0.14)))
                    .foregroundColor(brand)
            }
            accountMenu
        }
    }

    private var accountMenu: some View {
        Menu {
            Button(switchable ? "登入其他帳號…" : "在 Antigravity 切換帳號…", action: onLogin)
            if switchable && !others.isEmpty {
                Divider()
                ForEach(others, id: \.key) { r in
                    if r.hasCredential { Button("切換到 \(r.email)") { onSwitch(r.key) } }
                }
            }
            if !others.isEmpty {
                Divider()
                Menu("移除帳號") {
                    ForEach(others, id: \.key) { r in Button(r.email) { onRemove(r.key) } }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("帳號")
    }

    /// 不在使用中的帳號：數字來自它自己存的登入（還有效就即時查），否則是最後一次的紀錄，過了重置時間視為回滿。
    private var otherAccounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("其他帳號").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(others, id: \.key) { r in
                OtherAccountRow(record: r, now: now, brand: brand, canSwitch: switchable && r.hasCredential) { onSwitch(r.key) }
            }
        }
    }

    /// 大字：最緊那個額度的剩餘；右側：下次重置。
    private func summary(_ snapshot: Snapshot, _ head: UsageWindow) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(head.remaining.rounded()))")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Theme.level(head.remaining))
                    Text("%").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text("剩餘・\(head.name)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let next = snapshot.nextReset(after: now) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("下次重置").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(countdown(next, now: now)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(resetLabel(next, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func notice(_ error: String) -> some View {
        let stale = state.snapshot.map { s -> String in
            let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
            return "以上為 \(f.string(from: s.fetchedAt)) 的紀錄"
        }
        return HStack(spacing: 8) {
            Image(systemName: state.needsLogin ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .foregroundColor(state.needsLogin ? brand : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(error).font(.system(size: 12, weight: .medium))
                if let stale { Text(stale).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if state.needsLogin {
                Button(action: onLogin) {
                    Text(loginTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(brand))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill((state.needsLogin ? brand : Color.orange).opacity(0.10)))
    }

    private var loginTitle: String {
        if case .openApp = provider.login { return "開啟 Antigravity" }
        return "登入"
    }
}

struct OtherAccountRow: View {
    let record: AccountRecord
    let now: Date
    let brand: Color
    let canSwitch: Bool
    let onSwitch: () -> Void

    var body: some View {
        let snapshot = record.snapshot?.projected(now: now)
        let head = snapshot?.headline
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.email).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let plan = snapshot?.plan {
                        Text(plan).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                if let head {
                    HStack(spacing: 8) {
                        UsageBar(fraction: head.remaining / 100, color: Theme.level(head.remaining))
                        Text(percentText(head.remaining))
                            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .foregroundColor(Theme.level(head.remaining))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text(detail(snapshot)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            if canSwitch {
                Button(action: onSwitch) {
                    Text("切換").font(.system(size: 11.5, weight: .semibold)).foregroundColor(brand)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(brand.opacity(0.13)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .layoutPriority(1)
            }
        }
    }

    private func detail(_ snapshot: Snapshot?) -> String {
        guard let snapshot else { return record.error ?? "尚無資料" }
        var parts: [String] = []
        if let next = snapshot.nextReset(after: now) { parts.append("\(countdown(next, now: now)) 後重置") }
        if record.error == nil {
            parts.append("即時")
        } else {
            let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
            parts.append("\(f.string(from: snapshot.fetchedAt)) 的紀錄")
        }
        return parts.joined(separator: "・")
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(window.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let reset = window.resetsAt {
                    Text("\(countdown(reset, now: now))・\(resetLabel(reset, now: now))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                UsageBar(fraction: window.remaining / 100, color: Theme.level(window.remaining))
                Text(percentText(window.remaining))
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .opacity(window.headline ? 1 : 0.7)
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color).frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 驗證用：把儀表板畫成 PNG

@MainActor
func renderDashboardPNG(_ model: DashboardModel, dark: Bool, to path: String) {
    let host = NSHostingView(rootView: DashboardView(model: model)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
