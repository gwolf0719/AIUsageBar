import AppKit
import ServiceManagement

// 命令列模式（驗證用）：
//   --selftest            跑解析器與格式化的自我測試
//   --dump                實際抓一次三家用量並印出（不印任何金鑰）
//   --snapshot <png>      抓一次並把狀態列圖像輸出成 PNG
//   --login-item on|off|status
//   --render-dashboard <路徑>  把儀表板輸出成淺色／深色 PNG
//   --where               印出狀態列項目的螢幕位置（診斷是否被瀏海擠掉）
//   --terminal-test <檔案> 用登入同一條路徑開終端機，只建立標記檔
//   --accounts-test       用暫存檔與測試用鑰匙圈項目演練「存帳號→切換→切回」，不碰真正的登入

let args = CommandLine.arguments

func describe(_ results: [String: Result<Snapshot, UsageError>]) {
    for p in allProviders {
        switch results[p.id] {
        case .success(let s):
            print("\(p.title)  方案：\(s.plan ?? "?")")
            for w in s.windows {
                print("  \(w.headline ? "*" : " ") \(w.title)：剩 \(percentText(w.remaining))，\(countdown(w.resetsAt)) 後重置")
            }
        case .failure(let e): print("\(p.title)  ⚠︎ \(e.message)")
        case nil: print("\(p.title)  （無結果）")
        }
    }
}

if args.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
} else if args.contains("--accounts-test") {
    exit(runAccountsTest() ? 0 : 1)
} else if args.contains("--dump") || args.contains("--snapshot") {
    Task {
        let results = await fetchAll(allProviders)
        describe(results)
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            var states: [String: ProviderState] = [:]
            for (id, r) in results {
                if case .success(let s) = r { states[id] = ProviderState(snapshot: s) } else { states[id] = ProviderState() }
            }
            var columns = StatusRenderer.columns(allProviders, states)
            // 多畫兩欄示範「額度不足」與「資料過期」的樣子。
            columns.append(StatusColumn(icon: "claude", label: "CL", top: "12%", bottom: "45m", low: true))
            columns.append(StatusColumn(icon: "gemini", label: "GM", top: "60%", bottom: "2h10m", dim: true))
            try? StatusRenderer.writePNG(StatusRenderer.image(columns), to: args[i + 1])
        }
        exit(0)
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--render-dashboard"), i + 1 < args.count {
    // 驗證用：實際抓一次，把儀表板畫成淺色與深色兩張 PNG（<路徑>-light.png、<路徑>-dark.png）。
    Task { @MainActor in
        let results = await fetchAll(allProviders)
        let model = DashboardModel()
        for (id, r) in results {
            switch r {
            case .success(let s): model.states[id] = ProviderState(snapshot: s)
            case .failure(let e): model.states[id] = ProviderState(error: e.message, needsLogin: e.needsLogin)
            }
        }
        model.lastRefresh = Date()
        model.book = AccountVault().loadBook()
        renderDashboardPNG(model, dark: false, to: args[i + 1] + "-light.png")
        renderDashboardPNG(model, dark: true, to: args[i + 1] + "-dark.png")
        // 第三張：示範「未登入」「連線失敗＋額度偏低」的樣子（假資料，只用於檢查排版）。
        let soon = Date().addingTimeInterval(45 * 60)
        // 這張全部是假資料（不含真實帳號），README 的截圖用它。
        model.states["claude"] = ProviderState(error: "未登入", needsLogin: true)
        model.states["gemini"] = ProviderState(snapshot: Snapshot(plan: "Google AI Pro", windows: [
            UsageWindow(name: "5 小時", usedPercent: 8, resetsAt: Date().addingTimeInterval(4 * 3600), group: "Gemini"),
            UsageWindow(name: "每週", usedPercent: 42, resetsAt: Date().addingTimeInterval(4 * 86400 + 5 * 3600), group: "Gemini"),
            UsageWindow(name: "每週", usedPercent: 12, resetsAt: Date().addingTimeInterval(6 * 86400), group: "Gemini 4 Argon"),
            UsageWindow(name: "5 小時", usedPercent: 0, resetsAt: Date().addingTimeInterval(5 * 3600), headline: false, group: "Claude / GPT"),
            UsageWindow(name: "每週", usedPercent: 0, resetsAt: Date().addingTimeInterval(7 * 86400), headline: false, group: "Claude / GPT")],
            fetchedAt: Date(), account: "me@gmail.com", accountKey: "me@gmail.com"))
        model.states["codex"] = ProviderState(
            snapshot: Snapshot(plan: "plus", windows: [
                UsageWindow(name: "5 小時", usedPercent: 88, resetsAt: soon),
                UsageWindow(name: "每週", usedPercent: 61, resetsAt: Date().addingTimeInterval(3 * 86400))],
                fetchedAt: Date().addingTimeInterval(-1800), account: "me@example.com", accountKey: "a"),
            error: "連線失敗：網路離線")
        // 假的其他帳號：一個即時、一個舊紀錄且已過重置時間（應顯示回滿）。
        var demo = AccountBook()
        demo.active["codex"] = "a"
        demo.records = [
            AccountRecord(provider: "codex", key: "b", email: "work@example.com",
                          snapshot: Snapshot(plan: "team", windows: [UsageWindow(name: "每週", usedPercent: 35, resetsAt: Date().addingTimeInterval(2 * 86400))],
                                             fetchedAt: Date()), hasCredential: true),
            AccountRecord(provider: "codex", key: "c", email: "side-project@example.com",
                          snapshot: Snapshot(plan: "plus", windows: [UsageWindow(name: "每週", usedPercent: 97, resetsAt: Date().addingTimeInterval(-600))],
                                             fetchedAt: Date().addingTimeInterval(-86400 * 3)), error: "登入已過期", hasCredential: true),
            AccountRecord(provider: "gemini", key: "g2", email: "old@gmail.com",
                          snapshot: Snapshot(plan: "Free", windows: [UsageWindow(name: "Gemini 3 Pro", usedPercent: 80, resetsAt: Date().addingTimeInterval(3 * 3600))],
                                             fetchedAt: Date().addingTimeInterval(-7200)), error: "不在使用中", hasCredential: false),
        ]
        model.book = demo
        renderDashboardPNG(model, dark: false, to: args[i + 1] + "-states.png")
        // 第四張：螢幕高度不夠時，卡片區應改成捲動，標題與底列仍在。
        model.maxCardsHeight = 420
        renderDashboardPNG(model, dark: true, to: args[i + 1] + "-short.png")
        exit(0)
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--terminal-test"), i + 1 < args.count {
    // 驗證用：走跟「點這裡登入」完全相同的 .command 開啟路徑，只是指令換成建立一個標記檔。
    let ok = performLogin(.terminal(title: "AIUsageBar 終端機測試", command: "touch '\(args[i + 1])'"))
    print(ok ? "已交給終端機開啟" : "開啟失敗")
} else if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
    if args[i + 1] == "on" { setLoginItem(true) }
    if args[i + 1] == "off" { setLoginItem(false) }
    print("登入時自動啟動：\(SMAppService.mainApp.status == .enabled ? "開" : "關")")
} else {
    MainActor.assumeIsolated {
        // 瀏海機種選單列太擠時，新項目會被排到最左邊而看不見；第一次啟動時預設放在靠右的位置。
        // 之後使用者按住 ⌘ 拖曳調整的位置會被系統記住，不會再被這裡覆蓋。
        let positionKey = "NSStatusItem Preferred Position AIUsageBar"
        if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(260, forKey: positionKey) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
