import Foundation

/// 不依賴 XCTest（這台只有 Command Line Tools）：`AIUsageBar --selftest`，build.sh 每次建置都會跑。
func runSelfTest() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // 倒數格式
    check("倒數：天", countdown(now.addingTimeInterval(6 * 86400 + 23 * 3600 + 59), now: now) == "6d23h")
    check("倒數：小時", countdown(now.addingTimeInterval(2 * 3600 + 10 * 60), now: now) == "2h10m")
    check("倒數：分鐘", countdown(now.addingTimeInterval(45 * 60), now: now) == "45m")
    check("倒數：不足一分鐘顯示 1m", countdown(now.addingTimeInterval(20), now: now) == "1m")
    check("倒數：已過", countdown(now.addingTimeInterval(-5), now: now) == "已重置")
    check("倒數：未知", countdown(nil, now: now) == "--")
    check("完整倒數：天＋小時", countdownLong(now.addingTimeInterval(4 * 86400 + 13 * 3600 + 30), now: now) == "4 天 13 小時")
    check("完整倒數：整天", countdownLong(now.addingTimeInterval(2 * 86400 + 59), now: now) == "2 天")
    check("完整倒數：小時＋分", countdownLong(now.addingTimeInterval(4 * 3600 + 56 * 60), now: now) == "4 小時 56 分")
    check("完整倒數：分鐘、已過", countdownLong(now.addingTimeInterval(20), now: now) == "1 分鐘"
          && countdownLong(now.addingTimeInterval(-1), now: now) == "已重置")
    do {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 20, minute: 0))!  // 週一
        func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
        check("重置時刻：今天／明天", resetMoment(at(16, 21, 3), now: mon, calendar: cal) == "今天 21:03"
              && resetMoment(at(17, 1, 1), now: mon, calendar: cal) == "明天 01:01")
        check("重置時刻：一週內寫星期幾", resetMoment(at(21, 9, 4), now: mon, calendar: cal) == "週六 09:04")
        check("重置時刻：下週同一天加日期", resetMoment(at(23, 20, 1), now: mon, calendar: cal) == "11/23 週一 20:01")
    }
    check("ISO 含小數秒", parseISO("2026-11-16T08:03:10.123456+00:00") != nil)
    check("ISO 不含小數秒", parseISO("2026-11-22T14:15:38Z") != nil)

    // Codex（形狀取自 2026-11-16 實測回應）
    let codex = try? CodexProvider.parse(json("""
    {"plan_type":"prolite","rate_limit":{"allowed":true,"primary_window":{"used_percent":73,"limit_window_seconds":604800,
     "reset_after_seconds":603816,"reset_at":1795406560},"secondary_window":null},"additional_rate_limits":null}
    """), now: now)
    check("Codex：單一每週視窗", codex?.windows.map(\.name) == ["每週"] && codex?.plan == "prolite")
    check("Codex：剩餘 27%", codex?.headline?.remaining == 27)
    check("Codex：重置時間", codex?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1795406560))
    let codex2 = try? CodexProvider.parse(json("""
    {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1},
     "secondary_window":{"used_percent":95.5,"limit_window_seconds":604800,"reset_at":2}}}
    """), now: now)
    check("Codex：雙視窗取最緊的", codex2?.windows.count == 2 && codex2?.headline?.name == "每週")
    check("Codex：沒有額度資料要報錯", (try? CodexProvider.parse(json("{\"rate_limit\":null}"))) == nil)

    // Claude（形狀取自 /api/oauth/usage 文件）
    let claude = try? ClaudeProvider.parse(json("""
    {"five_hour":{"utilization":42.0,"resets_at":"2026-11-16T10:00:00.000000+00:00"},
     "seven_day":{"utilization":88,"resets_at":"2026-11-20T03:00:00+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":{"utilization":5,"resets_at":null}}
    """), now: now)
    check("Claude：略過 null 視窗", claude?.windows.map(\.name) == ["5 小時", "每週", "每週 Sonnet"])
    check("Claude：最緊的是每週 12%", claude?.headline?.name == "每週" && claude?.headline?.remaining == 12)
    check("Claude：重置時間可解析", claude?.windows.first?.resetsAt != nil && claude?.windows.last?.resetsAt == nil)
    check("Claude：方案名稱", ClaudeProvider.planName(["subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"]) == "Max 5x")
    check("Claude：空回應要報錯", (try? ClaudeProvider.parse(json("{}"))) == nil)

    // Gemini / Antigravity（形狀取自 2026-11-16 本機實測回應）
    let gemini = try? GeminiProvider.parse(json("""
    {"userStatus":{"userTier":{"name":"Google AI Pro"},"cascadeModelConfigData":{"clientModelConfigs":[
     {"label":"Gemini 4 Argon (Medium)","quotaInfo":{"remainingFraction":0.97,"resetTime":"2026-11-22T14:15:38Z"}},
     {"label":"Gemini 4 Argon (High)","quotaInfo":{"remainingFraction":0.97,"resetTime":"2026-11-22T14:15:38Z"}},
     {"label":"Claude Opus 5.5 (Low)","quotaInfo":{"remainingFraction":0.05,"resetTime":"2026-11-16T09:18:29Z"}},
     {"label":"Gemini 3.8 Flash (Low)","quotaInfo":{"resetTime":"2026-11-16T08:03:10Z"}},
     {"label":"Gemini 4 Carbon","quotaInfo":{}}]}}}
    """), now: now)
    check("Gemini：同池歸併、略過無配額模型", gemini?.windows.count == 3 && gemini?.plan == "Google AI Pro")
    check("Gemini：Gemini 系列排前面", gemini?.windows.map(\.headline) == [true, true, false])
    check("Gemini：缺 remainingFraction 視為用完", gemini?.headline?.name == "Gemini 3.8 Flash" && gemini?.headline?.remaining == 0)
    check("Gemini：非 Gemini 模型不影響狀態列", gemini?.headline?.name != "Claude Opus 5.5")
    // RetrieveUserQuotaSummary（形狀取自 2026-11-16 本機實測回應）
    let summary = GeminiProvider.parseSummary(json("""
    {"response":{"groups":[
     {"displayName":"Gemini Models","buckets":[
      {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.83,"resetTime":"2026-11-21T01:04:55Z"},
      {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-16T13:03:10Z"}]},
     {"displayName":"Claude and GPT models","buckets":[
      {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-11-23T12:01:12Z"},
      {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2026-11-16T17:01:12Z"}]},
     {"displayName":"Gemini 4 Argon","buckets":[
      {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.97,"resetTime":"2026-11-22T14:15:38Z"}]}]}}
    """))
    check("Gemini 摘要：每個群組的 5 小時與每週都有、5 小時在前", summary?.map(\.title)
          == ["Gemini 5 小時", "Gemini 每週", "Gemini 4 Argon 每週", "Claude / GPT 5 小時", "Claude / GPT 每週"])
    check("Gemini 摘要：每週有下次重置時間", summary?.first { $0.title == "Gemini 每週" }?.resetsAt == parseISO("2026-11-21T01:04:55Z"))
    check("Gemini 摘要：缺 remainingFraction 視為用完、只有 Gemini 影響狀態列",
          summary.map { Snapshot(windows: $0, fetchedAt: Date()) }?.headline?.title == "Gemini 5 小時"
          && summary?.filter(\.headline).count == 3)
    check("Gemini 摘要：格式不符回傳 nil", GeminiProvider.parseSummary(json(#"{"response":{}}"#)) == nil
          && GeminiProvider.parseSummary(json(#"{"response":{"groups":[]}}"#)) == nil)
    check("Gemini：解析啟動參數", GeminiProvider.argument("--csrf_token", in: "/x/language_server --a 1 --csrf_token abc-123 --b") == "abc-123"
          && GeminiProvider.argument("--csrf_token", in: "ls --csrf_token=zzz") == "zzz"
          && GeminiProvider.argument("--csrf_token", in: "ls --other") == nil)
    let oldSecret = #"{"claudeAiOauth":{"accessToken":"a1","expiresAt":1000,"rateLimitTier":"default_claude_max_5x","refreshToken":"r1","scopes":["user:inference"]},"other":{"keep":1}}"#
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let merged = ClaudeProvider.renewed(oldSecret, with: ["access_token": "a2", "refresh_token": "r2", "expires_in": 3600], now: t0)
    let mergedRoot = merged.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    let mergedOAuth = mergedRoot?["claudeAiOauth"] as? [String: Any] ?? [:]
    check("Claude：換發回應併入憑證", mergedOAuth["accessToken"] as? String == "a2" && mergedOAuth["refreshToken"] as? String == "r2"
          && double(mergedOAuth["expiresAt"]) == 2_003_600_000 && mergedOAuth["rateLimitTier"] as? String == "default_claude_max_5x"
          && mergedOAuth["scopes"] as? [String] == ["user:inference"] && (mergedRoot?["other"] as? [String: Any])?["keep"] as? Int == 1)
    check("Claude：回應沒有新 refresh token 就沿用舊的",
          ((ClaudeProvider.renewed(oldSecret, with: ["access_token": "a2", "expires_in": 60], now: t0).flatMap(ClaudeProvider.oauth))?["refreshToken"] as? String) == "r1")
    check("Claude：換發回應不完整就不採用", ClaudeProvider.renewed(oldSecret, with: ["refresh_token": "r2", "expires_in": 60]) == nil
          && ClaudeProvider.renewed(oldSecret, with: ["access_token": "a2"]) == nil && ClaudeProvider.renewed(oldSecret, with: nil) == nil)
    check("Claude：到期判斷", ClaudeProvider.expired(oldSecret, now: t0) && !ClaudeProvider.expired(merged ?? "", now: t0)
          && !ClaudeProvider.expired(#"{"claudeAiOauth":{"accessToken":"a"}}"#))
    // 2.34 起命令列沒有 --csrf_token，權杖在 `ps eww` 尾端的環境變數裡。
    check("Gemini：CSRF 權杖（參數或環境變數）",
          GeminiProvider.csrfToken(in: "/x/language_server --standalone --https_server_port 0 HOME=/Users/me ANTIGRAVITY_SERVER_CSRF_TOKEN=aa-11 LANG=zh_TW.UTF-8") == "aa-11"
          && GeminiProvider.csrfToken(in: "ls --csrf_token old ANTIGRAVITY_SERVER_CSRF_TOKEN=new") == "old"
          && GeminiProvider.csrfToken(in: "ls --standalone ANTIGRAVITY_SERVER_CSRF_TOKEN=") == nil
          && GeminiProvider.csrfToken(in: "ls --standalone HOME=/x") == nil)

    // 狀態列欄位
    let columns = StatusRenderer.columns([CodexProvider(), ClaudeProvider()],
                                         ["codex": ProviderState(snapshot: codex2, error: "離線")], now: now)
    check("狀態列：低額度反白＋過期變淡", columns[0].top == "5%" && columns[0].icon == "codex" && columns[0].low && columns[0].dim)
    check("狀態列：沒有資料顯示破折號", columns[1].top == "—" && columns[1].bottom == "--")

    // 下次重置：取最近、且還沒過的
    let resets = Snapshot(plan: nil, windows: [
        UsageWindow(name: "a", usedPercent: 0, resetsAt: now.addingTimeInterval(-60)),
        UsageWindow(name: "b", usedPercent: 0, resetsAt: now.addingTimeInterval(7200)),
        UsageWindow(name: "c", usedPercent: 0, resetsAt: now.addingTimeInterval(3600)),
        UsageWindow(name: "d", usedPercent: 0, resetsAt: nil)], fetchedAt: now)
    check("下次重置：略過已過與未知", resets.nextReset(after: now) == now.addingTimeInterval(3600))
    check("下次重置：全部已過回傳 nil", Snapshot(plan: nil, windows: [resets.windows[0]], fetchedAt: now).nextReset(after: now) == nil)

    // 未登入：狀態列顯示「未登入」，登入腳本內容正確
    let loggedOut = StatusRenderer.columns([ClaudeProvider()], ["claude": ProviderState(error: "未登入", needsLogin: true)], now: now)
    check("狀態列：未登入提示", loggedOut[0].top == "—" && loggedOut[0].label == "CL" && loggedOut[0].bottom == "未登入")
    let script = loginScript(title: "登入 Claude", command: "claude auth login")
    check("登入腳本：zsh 登入殼層並執行指令", script.hasPrefix("#!/bin/zsh -l\n") && script.contains("\nclaude auth login\n"))
    if case .terminal(_, let cmd) = ClaudeProvider().login { check("Claude 登入指令", cmd == "claude auth login") } else { check("Claude 登入指令", false) }
    if case .terminal(_, let cmd) = CodexProvider().login { check("Codex 登入指令", cmd == "codex login") } else { check("Codex 登入指令", false) }

    // 紀錄可往返
    if let codex, let data = try? JSONEncoder().encode(["codex": codex]) {
        check("紀錄：編碼後可還原", (try? JSONDecoder().decode([String: Snapshot].self, from: data))?["codex"] == codex)
    } else { check("紀錄：編碼後可還原", false) }

    // 多帳號
    let stale = Snapshot(plan: nil, windows: [
        UsageWindow(name: "5 小時", usedPercent: 90, resetsAt: now.addingTimeInterval(-60)),
        UsageWindow(name: "每週", usedPercent: 40, resetsAt: now.addingTimeInterval(3600))], fetchedAt: now)
    check("推估：過了重置時間視為回滿", stale.projected(now: now).windows.map(\.usedPercent) == [0, 40]
          && stale.projected(now: now).headline?.name == "每週")
    let codexAuth = fakeCodexAuth(email: "a@example.com", account: "acc-1", exp: now.addingTimeInterval(86400))
    let cred = CodexProvider.credential(from: codexAuth)
    check("Codex：從 JWT 認出帳號", cred?.email == "a@example.com" && cred?.key == "acc-1|a@example.com")
    check("JWT：壞格式回傳 nil", jwtClaims("abc") == nil)
    check("鑰匙圈屬性解析", keychainAttribute("acct", in: "    \"acct\"<blob>=\"me\"\n    \"svce\"<blob>=\"x\"") == "me")
    var book = AccountBook()
    book.active["codex"] = "k1"
    book.upsert(AccountRecord(provider: "codex", key: "k1", email: "b@x", hasCredential: true))
    book.upsert(AccountRecord(provider: "codex", key: "k2", email: "a@x", hasCredential: true))
    book.upsert(AccountRecord(provider: "claude", key: "k3", email: "c@x", hasCredential: true))
    book.upsert(AccountRecord(provider: "codex", key: "k2", email: "a2@x", hasCredential: false))
    check("帳號簿：其他帳號不含使用中、不重複", book.others("codex").map(\.email) == ["a2@x"] && book.records.count == 3)
    if let old = try? JSONDecoder().decode(Snapshot.self, from: Data(#"{"windows":[],"fetchedAt":0}"#.utf8)) {
        check("舊版紀錄（沒有帳號欄位）可讀", old.account == nil)
    } else { check("舊版紀錄（沒有帳號欄位）可讀", false) }

    print(failures == 0 ? "全部通過" : "\(failures) 項失敗")
    return failures == 0
}

/// 測試用的假 auth.json（JWT 沒有簽章，只有 payload）。
func fakeCodexAuth(email: String, account: String, exp: Date) -> String {
    let payload: [String: Any] = ["exp": exp.timeIntervalSince1970, "https://api.openai.com/profile": ["email": email]]
    let b64 = (try! JSONSerialization.data(withJSONObject: payload)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let auth: [String: Any] = ["tokens": ["access_token": "e30.\(b64).sig", "account_id": account, "refresh_token": "r-\(account)"]]
    return String(data: try! JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys]), encoding: .utf8)!
}

/// 記錄假的換發介面被呼叫了幾次、收到哪些 refresh token。
actor CallLog {
    private(set) var seen: [String] = []
    var count: Int { seen.count }
    func add(_ token: String) -> Int { seen.append(token); return seen.count }
}

/// 測試用：在同步的測試流程裡等一段 async 工作做完。
final class ResultBox<T>: @unchecked Sendable { var value: T? }

func blocking<T>(_ work: @escaping () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await work(); done.signal() }
    done.wait()
    return box.value!
}

/// 演練切換與換發：全部用暫存資料夾與測試專用的鑰匙圈項目，不碰真正的 CLI 登入。
func runAccountsTest() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "✓" : "✗", name); if !ok { failures += 1 } }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageBar-accounts-\(UUID().uuidString)")
    let service = "AIUsageBar-accounts-test"
    defer {
        try? FileManager.default.removeItem(at: tmp)
        _ = shell("/usr/bin/security", ["delete-generic-password", "-s", service])
    }
    let vault = AccountVault(dir: tmp.appendingPathComponent("vault"))
    let read = { (path: String) in FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }

    // Codex：A 登入中 → 被存起來 → 登入 B → 切回 A → 再切到 B
    let codex = CodexProvider(authPath: tmp.appendingPathComponent("codex/auth.json").path)
    let future = Date().addingTimeInterval(86400)
    let authA = fakeCodexAuth(email: "a@example.com", account: "A", exp: future)
    let authB = fakeCodexAuth(email: "b@example.com", account: "B", exp: future)
    try? writePrivateFile(Data(authA.utf8), to: codex.authPath)
    let keyA = codex.readActive()!.key
    vault.save("codex", codex.readActive()!)
    try? writePrivateFile(Data(authB.utf8), to: codex.authPath)
    let keyB = codex.readActive()!.key
    do {
        try switchAccount(codex, provider: "codex", to: keyA, vault: vault)
        check("Codex：切到 A", read(codex.authPath) == authA)
        check("Codex：切換前自動存下 B", vault.load("codex", keyB)?.secret == authB)
        let mode = (try? FileManager.default.attributesOfItem(atPath: codex.authPath)[.posixPermissions] as? Int) ?? 0
        check("Codex：auth.json 權限 0600", mode == 0o600)
        try switchAccount(codex, provider: "codex", to: keyB, vault: vault)
        check("Codex：切回 B", read(codex.authPath) == authB)
    } catch { check("Codex 切換：\(error.localizedDescription)", false) }

    // Claude：鑰匙圈（測試項目）＋ ~/.claude.json 的 oauthAccount（暫存檔）
    let claude = ClaudeProvider(keychainService: service, credentialsFile: tmp.appendingPathComponent("none.json").path,
                                configPath: tmp.appendingPathComponent("claude.json").path)
    func claudeSecret(_ n: String) -> String { #"{"claudeAiOauth":{"accessToken":"at-\#(n)","expiresAt":9999999999999,"refreshToken":"rt-\#(n)","scopes":["user:inference"],"subscriptionType":"max"}}"# }
    func config(_ n: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["numStartups": 42, "projects": ["/x": ["a": 1]],
                                                     "oauthAccount": ["accountUuid": "u-\(n)", "organizationUuid": "o", "emailAddress": "\(n)@example.com"]])
    }
    do {
        try keychainWrite(service: service, account: NSUserName(), secret: claudeSecret("A"))
        try writePrivateFile(config("A"), to: claude.configPath)
        let a = claude.readActive()
        check("Claude：認出 A", a?.email == "A@example.com" && a?.secret == claudeSecret("A"))
        vault.save("claude", a!)
        try keychainWrite(service: service, account: NSUserName(), secret: claudeSecret("B"))
        try writePrivateFile(config("B"), to: claude.configPath)
        try switchAccount(claude, provider: "claude", to: a!.key, vault: vault)
        let now = claude.readActive()
        check("Claude：鑰匙圈換回 A", now?.secret == claudeSecret("A"))
        check("Claude：oauthAccount 換回 A", now?.email == "A@example.com")
        let cfg = readJSON(claude.configPath) ?? [:]
        check("Claude：其他設定保留", (cfg["numStartups"] as? Int) == 42 && (cfg["projects"] as? [String: Any])?["/x"] != nil)
        check("Claude：B 已存起來可切回", vault.load("claude", "u-B|o")?.secret == claudeSecret("B"))
        check("Claude：切換前有備份設定檔", FileManager.default.fileExists(atPath: vault.dir.appendingPathComponent("backup-claude.json").path))
    } catch { check("Claude 切換：\(error.localizedDescription)", false) }

    // Claude 換發：假的換發回應＋測試鑰匙圈項目。
    let renewing: ClaudeProvider = {
        var c = claude; c.pendingPath = tmp.appendingPathComponent("vault/claude-pending.json").path; return c
    }()
    let calls = CallLog()
    @Sendable func exchange(status: Int = 200) -> ClaudeProvider.TokenExchange {
        { refresh, _ in
            let n = await calls.add(refresh)
            try? await Task.sleep(nanoseconds: 200_000_000)   // 拉長一點，讓同時進來的第二個請求撞上
            return (status, ["access_token": "at-new\(n)", "refresh_token": "rt-new\(n)", "expires_in": 28800,
                             "refresh_token_expires_in": 2_592_000, "scope": "user:inference user:profile"])
        }
    }
    func stale(_ n: String) -> String { claudeSecret(n).replacingOccurrences(of: "9999999999999", with: "1000") }
    func oauth(_ secret: String?) -> [String: Any] { secret.flatMap(ClaudeProvider.oauth) ?? [:] }
    let pendingExists = { FileManager.default.fileExists(atPath: renewing.pendingPath) }
    do {
        try keychainWrite(service: service, account: NSUserName(), secret: claudeSecret("A"))
        _ = blocking { try? await renewing.activeCredential(exchange: exchange()) }
        check("換發：沒過期不換", blocking { await calls.count } == 0)

        try keychainWrite(service: service, account: NSUserName(), secret: stale("A"))
        let pair = blocking { () -> [String?] in
            async let x = try? renewing.activeCredential(exchange: exchange())
            async let y = try? renewing.activeCredential(exchange: exchange())
            return [await x?.secret, await y?.secret]
        }
        let stored = oauth(renewing.readActive()?.secret)
        check("換發：同時兩個請求只換一次", blocking { await calls.seen } == ["rt-A"] && pair[0] != nil && pair[0] == pair[1])
        check("換發：新憑證寫回鑰匙圈", stored["accessToken"] as? String == "at-new1" && stored["refreshToken"] as? String == "rt-new1"
              && pair[0] == renewing.readActive()?.secret)
        check("換發：到期時間更新、其他欄位保留", !ClaudeProvider.expired(renewing.readActive()!.secret)
              && (double(stored["refreshTokenExpiresAt"]) ?? 0) > Date().timeIntervalSince1970 * 1000
              && stored["subscriptionType"] as? String == "max" && (stored["scopes"] as? [String])?.count == 2)
        check("換發：成功後不留暫存", !pendingExists())

        try keychainWrite(service: service, account: NSUserName(), secret: stale("B"))
        let denied = blocking { () -> UsageError? in
            do { _ = try await renewing.activeCredential(exchange: exchange(status: 400)); return nil } catch { return error as? UsageError }
        }
        check("換發：被拒絕就要求重新登入，鑰匙圈不動", denied?.needsLogin == true && renewing.readActive()?.secret == stale("B") && !pendingExists())

        // 上次換到新憑證但沒寫成功：下次補寫，不再換一次。
        let before = blocking { await calls.count }
        let left = ClaudeProvider.PendingRenewal(replaces: ClaudeProvider.digest(stale("B")), secret: claudeSecret("B2"))
        try writePrivateFile(try JSONEncoder().encode(left), to: renewing.pendingPath)
        let recovered = blocking { try? await renewing.activeCredential(exchange: exchange()) }
        check("換發：補寫上次沒寫成功的新憑證", recovered?.secret == claudeSecret("B2") && renewing.readActive()?.secret == claudeSecret("B2")
              && !pendingExists() && blocking { await calls.count } == before)

        // CLI 已自行更新（登入位置不是被換掉的那份）：暫存作廢。
        try writePrivateFile(try JSONEncoder().encode(left), to: renewing.pendingPath)
        _ = blocking { try? await renewing.activeCredential(exchange: exchange()) }
        check("換發：登入位置已被 CLI 更新就丟掉暫存", renewing.readActive()?.secret == claudeSecret("B2") && !pendingExists())

        // 登入位置寫不進去（唯讀資料夾裡的憑證檔）：不可以把 refresh token 用掉。
        _ = shell("/usr/bin/security", ["delete-generic-password", "-s", service])
        let locked = tmp.appendingPathComponent("locked")
        var filed = renewing
        filed.credentialsFile = locked.appendingPathComponent("credentials.json").path
        try writePrivateFile(Data(stale("C").utf8), to: filed.credentialsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let count = blocking { await calls.count }
        let blocked = blocking { () -> UsageError? in
            do { _ = try await filed.activeCredential(exchange: exchange()); return nil } catch { return error as? UsageError }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        check("換發：寫不進登入位置就不換", blocked?.needsLogin == true && blocking { await calls.count } == count && read(filed.credentialsFile) == stale("C"))
    } catch { check("Claude 換發：\(error.localizedDescription)", false) }

    print(failures == 0 ? "全部通過" : "\(failures) 項失敗")
    return failures == 0
}
