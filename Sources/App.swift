import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 紀錄：~/Library/Application Support/AIUsageBar/

struct Store {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AIUsageBar")
    private var lastURL: URL { dir.appendingPathComponent("last.json") }
    private var historyURL: URL { dir.appendingPathComponent("history.jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func load() -> [String: Snapshot] {
        guard let data = try? Data(contentsOf: lastURL) else { return [:] }
        return (try? Self.decoder.decode([String: Snapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [String: Snapshot]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.encoder.encode(snapshots).write(to: lastURL, options: .atomic)
    }

    /// 每次數值有變動就追加一行（JSON Lines），方便之後用 jq / 試算表分析。
    func appendHistory(_ id: String, _ snapshot: Snapshot) {
        struct Line: Encodable { let provider: String; let snapshot: Snapshot }
        guard var data = try? Self.encoder.encode(Line(provider: id, snapshot: snapshot)) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: historyURL)
        }
    }
}

// MARK: - 狀態列圖像（每家一欄：上排「品牌圖示 剩餘%」、下排「重置倒數」）

struct StatusColumn {
    /// 品牌圖示（Resources/<icon>.svg）；找不到圖時改畫 label 文字。
    var icon = ""
    var label = ""
    var top: String
    var bottom: String
    var low = false   // 剩餘不足 20%：上排反白
    var dim = false   // 資料不是最新：整欄變淡
}

enum StatusRenderer {
    static func columns(_ providers: [Provider], _ states: [String: ProviderState], now: Date = Date()) -> [StatusColumn] {
        providers.map { p in
            let state = states[p.id] ?? ProviderState()
            guard let w = state.snapshot?.headline else {
                return StatusColumn(icon: p.id, label: p.short, top: "—", bottom: state.needsLogin ? "未登入" : "--", dim: true)
            }
            return StatusColumn(icon: p.id, label: p.short, top: percentText(w.remaining), bottom: countdown(w.resetsAt, now: now),
                                low: w.remaining < 20, dim: state.error != nil)
        }
    }

    static func icon(_ name: String) -> NSImage? {
        guard !name.isEmpty, let url = Bundle.main.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func image(_ columns: [StatusColumn]) -> NSImage {
        // 圖示放不進來時（例如沒有包成 .app 執行），退回文字代號。
        let icons = columns.map { icon($0.icon) }
        let columns = zip(columns, icons).map { c, icon -> StatusColumn in
            var c = c
            if icon == nil, !c.label.isEmpty { c.top = "\(c.label) \(c.top)" }
            return c
        }
        let iconSize: CGFloat = 9.5, iconGap: CGFloat = 2.5
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let gap: CGFloat = 9, pad: CGFloat = 3
        func text(_ s: String, _ font: NSFont, _ alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
        }
        func topWidth(_ i: Int) -> CGFloat {
            text(columns[i].top, topFont, 1).size().width + (icons[i] == nil ? 0 : iconSize + iconGap)
        }
        let widths = columns.indices.map { i in
            ceil(max(topWidth(i), text(columns[i].bottom, bottomFont, 1).size().width)) + pad * 2
        }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, columns.count - 1))
        let image = NSImage(size: NSSize(width: max(total, 1), height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, (c, width)) in zip(columns, widths).enumerated() {
                let alpha: CGFloat = c.dim ? 0.45 : 1
                let top = text(c.top, topFont, c.low ? 1 : alpha), bottom = text(c.bottom, bottomFont, alpha)
                let startX = x + (width - topWidth(i)) / 2
                let iconRect = NSRect(x: startX, y: 11.5, width: iconSize, height: iconSize)
                let topOrigin = NSPoint(x: startX + (icons[i] == nil ? 0 : iconSize + iconGap), y: 10.5)
                if c.low {
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 10.5, width: width, height: 11.5), xRadius: 3, yRadius: 3).fill()
                    icons[i]?.draw(in: iconRect, from: .zero, operation: .destinationOut, fraction: 1)
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    top.draw(at: topOrigin)
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                } else {
                    icons[i]?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha)
                    top.draw(at: topOrigin)
                }
                bottom.draw(at: NSPoint(x: x + (width - bottom.size().width) / 2, y: 0))
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 驗證用：把狀態列圖像放大畫在白底上輸出成 PNG。
    static func writePNG(_ image: NSImage, to path: String, scale: CGFloat = 4) throws {
        let size = NSSize(width: image.size.width + 12, height: image.size.height + 8)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(x: 6, y: 4, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let pollInterval: TimeInterval = 300

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = Store()
    private let model = DashboardModel()
    private let vault = AccountVault()
    private var book = AccountBook() {
        didSet { model.book = book }
    }
    private let popover = NSPopover()
    private var states: [String: ProviderState] = [:] {
        didSet { model.states = states }
    }
    private var lastRefresh = Date.distantPast
    private var refreshing = false {
        didSet { model.refreshing = refreshing }
    }
    /// 使用者按了登入之後的這段時間內，每 15 秒查一次，登入完成能馬上反映。
    private var fastPollUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        for (id, snapshot) in store.load() { states[id] = ProviderState(snapshot: snapshot, error: "尚未更新") }
        book = vault.loadBook()
        item.autosaveName = "AIUsageBar"

        model.onRefresh = { [weak self] in self?.refresh() }
        model.onOpenStore = { [weak self] in self?.openStore() }
        model.onLogin = { [weak self] provider in self?.login(provider) }
        model.onSwitch = { [weak self] provider, key in self?.confirmSwitch(provider, key) }
        model.onRemove = { [weak self] provider, key in self?.confirmRemove(provider, key) }
        let hosting = NSHostingController(rootView: DashboardView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        render()
        refresh()
        if CommandLine.arguments.contains("--where") {
            // 診斷用：印出狀態列項目的實際位置後結束（瀏海機種項目太多時會被擠到看不見）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [item] in
                let w = item.button?.window
                print("frame:", w?.frame ?? .zero, "visible:", w?.occlusionState.contains(.visible) ?? false,
                      "screen:", w?.screen?.frame ?? .zero, "safeTop:", w?.screen?.safeAreaInsets.top ?? 0)
                exit(0)
            }
        }
        let poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        poll.tolerance = 30
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date() < self.fastPollUntil else { return }
                // 只看本機登入狀態有沒有變（新帳號登入完成、或登入恢復），有變才真的去查網路。
                let changed = allProviders.contains { p in
                    guard let source = p as? CredentialSource else { return false }
                    return source.readActive()?.key != self.book.active[p.id]
                }
                if changed || self.states.values.contains(where: \.needsLogin) { self.refresh() }
            }
        }
        // 倒數每分鐘重畫一次（不打網路）。
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        model.now = Date()
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let (next, nextBook) = await refreshEverything(allProviders, states: states, book: book, vault: vault)
            // 紀錄：任何帳號的數值有變就追加一行（snapshot 內含帳號 email）。
            for r in nextBook.records {
                guard let s = r.snapshot, book.record(r.provider, r.key)?.snapshot?.windows != s.windows else { continue }
                store.appendHistory(r.provider, s)
            }
            states = next
            book = nextBook
            vault.saveBook(book)
            store.save(states.compactMapValues(\.snapshot))
            lastRefresh = Date()
            model.lastRefresh = lastRefresh
            refreshing = false
            render()
        }
    }

    private func render() {
        model.now = Date()
        item.button?.image = StatusRenderer.image(StatusRenderer.columns(allProviders, states))
        item.button?.toolTip = "AI 用量：剩餘百分比／距離重置"
    }

    // MARK: 帳號

    private func login(_ provider: Provider) {
        popover.performClose(nil)
        // 登入新帳號會蓋掉 CLI 現在的登入：先把目前這份存起來，之後才切得回來。
        if let source = provider as? CredentialSource, let current = source.readActive() { vault.save(provider.id, current) }
        performLogin(provider.login)
        fastPollUntil = Date().addingTimeInterval(300)
    }

    private func ask(_ title: String, _ detail: String, confirm: String) -> Bool {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSwitch(_ provider: Provider, _ key: String) {
        guard let source = provider as? CredentialSource, let target = book.record(provider.id, key) else { return }
        let name = provider.title.components(separatedBy: "（").first ?? provider.title
        let current = book.active[provider.id].flatMap { book.record(provider.id, $0)?.email } ?? "目前的帳號"
        guard ask("把 \(name) 切換到 \(target.email)？",
                  "\(current) 的登入會先存起來，之後隨時可以切回來。已經開著的 \(provider.id == "claude" ? "claude" : "codex") 要重新開啟才會換成新帳號。",
                  confirm: "切換") else { return }
        do {
            try switchAccount(source, provider: provider.id, to: key, vault: vault)
            refresh()
        } catch {
            let alert = NSAlert()
            alert.messageText = "切換失敗"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func confirmRemove(_ provider: Provider, _ key: String) {
        guard let record = book.record(provider.id, key),
              ask("移除 \(record.email)？", "只會刪掉本工具存的登入副本與紀錄，不會登出 CLI，也不影響帳號本身。", confirm: "移除") else { return }
        vault.delete(provider.id, key)
        book.remove(provider.id, key)
        vault.saveBook(book)
    }

    private func openStore() {
        popover.performClose(nil)
        try? FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.dir)
    }
}

@discardableResult
func setLoginItem(_ enabled: Bool) -> Bool {
    do {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return true
    } catch {
        FileHandle.standardError.write(Data("登入項目設定失敗：\(error.localizedDescription)\n".utf8))
        return false
    }
}
