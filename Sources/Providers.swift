import AppKit

// 平常只「讀」本機 CLI 的登入狀態，絕不自行換發 refresh token
// （Claude / Codex 的 refresh token 會輪替，自行換發會把 CLI 的登入弄壞）。
// 唯一會寫入 CLI 登入位置的時機：使用者在儀表板按「切換」帳號（見 Accounts.swift）。

// MARK: - ChatGPT（Codex CLI：~/.codex/auth.json）

struct CodexProvider: Provider, CredentialSource {
    let id = "codex", short = "GPT", title = "ChatGPT（Codex CLI）"
    let login = LoginAction.terminal(title: "登入 ChatGPT（Codex CLI）", command: "codex login")
    var authPath = ("~/.codex/auth.json" as NSString).expandingTildeInPath

    func fetch() async throws -> Snapshot {
        guard let active = readActive() else { throw UsageError("未登入", needsLogin: true) }
        return try await fetch(active)
    }

    func readActive() -> SavedCredential? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.credential(from: text)
    }

    /// 從 auth.json 全文辨識帳號（email 取自 JWT，不驗簽，只用來顯示與分辨）。
    static func credential(from text: String) -> SavedCredential? {
        guard let auth = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        let claims = jwtClaims(token) ?? [:]
        let idClaims = (tokens["id_token"] as? String).flatMap(jwtClaims) ?? [:]
        let email = ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
            ?? (idClaims["email"] as? String) ?? "ChatGPT 帳號"
        let account = tokens["account_id"] as? String ?? ""
        return SavedCredential(key: "\(account)|\(email)", email: email, secret: text)
    }

    func fetch(_ credential: SavedCredential) async throws -> Snapshot {
        guard let auth = (try? JSONSerialization.jsonObject(with: Data(credential.secret.utf8))) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw UsageError("未登入", needsLogin: true)
        }
        if let exp = double(jwtClaims(token)?["exp"]), exp < Date().timeIntervalSince1970 {
            throw UsageError("登入已過期", needsLogin: true)
        }
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "AIUsageBar"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let (status, body) = try await http("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        if status == 401 || status == 403 { throw UsageError("登入已失效", needsLogin: true) }
        guard status == 200, let body else { throw UsageError("ChatGPT 回應 HTTP \(status)") }
        var snapshot = try Self.parse(body)
        snapshot.account = credential.email
        snapshot.accountKey = credential.key
        return snapshot
    }

    func activate(_ credential: SavedCredential) throws {
        try writePrivateFile(Data(credential.secret.utf8), to: authPath)
    }

    static func parse(_ body: Any, now: Date = Date()) throws -> Snapshot {
        guard let root = body as? [String: Any] else { throw UsageError("ChatGPT 回應格式不符") }
        var windows: [UsageWindow] = []
        func add(_ limit: Any?, prefix: String = "") {
            guard let limit = limit as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let w = limit[key] as? [String: Any], let used = double(w["used_percent"]) else { continue }
                let reset = double(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                windows.append(UsageWindow(name: prefix + windowName(Int(double(w["limit_window_seconds"]) ?? 0)),
                                           usedPercent: used, resetsAt: reset))
            }
        }
        add(root["rate_limit"])
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "其他"
            add(extra["rate_limit"], prefix: name + " ")
        }
        guard !windows.isEmpty else { throw UsageError("ChatGPT 沒有回傳額度資料") }
        return Snapshot(plan: root["plan_type"] as? String, windows: windows, fetchedAt: now)
    }

    static func windowName(_ seconds: Int) -> String {
        switch seconds {
        case 18000: return "5 小時"
        case 86400: return "每日"
        case 604800: return "每週"
        case 2592000: return "每月"
        case 0: return "額度"
        default: return seconds % 86400 == 0 ? "\(seconds / 86400) 天" : "\(seconds / 3600) 小時"
        }
    }
}

// MARK: - Claude（Claude Code CLI：鑰匙圈「Claude Code-credentials」或 ~/.claude/.credentials.json）

struct ClaudeProvider: Provider, CredentialSource {
    let id = "claude", short = "CL", title = "Claude（Claude Code CLI）"
    let login = LoginAction.terminal(title: "登入 Claude（Claude Code CLI）", command: "claude auth login")
    var keychainService = "Claude Code-credentials"
    var credentialsFile = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
    /// Claude Code 把「目前登入的是誰」（email、組織）放在這裡，跟鑰匙圈裡的 token 是一組。
    var configPath = ("~/.claude.json" as NSString).expandingTildeInPath

    func fetch() async throws -> Snapshot {
        guard let active = readActive() else { throw UsageError("未登入", needsLogin: true) }
        return try await fetch(active)
    }

    func readActive() -> SavedCredential? {
        // 透過系統的 security 工具讀鑰匙圈：Claude Code 自己就是用它寫入，不會跳授權視窗。
        let raw = shell("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = raw.flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.contents(atPath: credentialsFile).flatMap { String(data: $0, encoding: .utf8) }
        guard let secret, Self.oauth(secret) != nil else { return nil }
        let account = (readJSON(configPath)?["oauthAccount"] as? [String: Any]) ?? [:]
        let extra = (try? JSONSerialization.data(withJSONObject: account, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let key = "\(account["accountUuid"] as? String ?? "?")|\(account["organizationUuid"] as? String ?? "?")"
        return SavedCredential(key: key, email: account["emailAddress"] as? String ?? "Claude 帳號",
                               secret: secret, extra: account.isEmpty ? nil : extra)
    }

    static func oauth(_ secret: String) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: Data(secret.utf8))) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
    }

    func fetch(_ credential: SavedCredential) async throws -> Snapshot {
        guard let oauth = Self.oauth(credential.secret),
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError("未登入", needsLogin: true)
        }
        if let expires = double(oauth["expiresAt"]), expires > 0, expires / 1000 < Date().timeIntervalSince1970 {
            throw UsageError("登入已過期", needsLogin: true)
        }
        let (status, body) = try await http("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
        ])
        if status == 401 || status == 403 { throw UsageError("登入已失效", needsLogin: true) }
        if status == 429 { throw UsageError("Claude 查詢過於頻繁，稍後自動重試") }
        guard status == 200, let body else { throw UsageError("Claude 回應 HTTP \(status)") }
        var snapshot = try Self.parse(body)
        snapshot.plan = Self.planName(oauth)
        snapshot.account = credential.email
        snapshot.accountKey = credential.key
        return snapshot
    }

    /// 切換：把 token 寫回鑰匙圈（或檔案），並把 ~/.claude.json 的 oauthAccount 換成同一個帳號。
    func activate(_ credential: SavedCredential) throws {
        let existing = shell("/usr/bin/security", ["find-generic-password", "-s", keychainService]) ?? ""
        let usesFile = existing.isEmpty && FileManager.default.fileExists(atPath: credentialsFile)
        if usesFile {
            try writePrivateFile(Data(credential.secret.utf8), to: credentialsFile)
        } else {
            let acct = keychainAttribute("acct", in: existing) ?? NSUserName()
            try keychainWrite(service: keychainService, account: acct, secret: credential.secret)
        }
        guard let extra = credential.extra,
              let account = try? JSONSerialization.jsonObject(with: Data(extra.utf8)),
              let data = FileManager.default.contents(atPath: configPath),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        config["oauthAccount"] = account
        let out = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    static func parse(_ body: Any, now: Date = Date()) throws -> Snapshot {
        guard let root = body as? [String: Any] else { throw UsageError("Claude 回應格式不符") }
        let names = [("five_hour", "5 小時"), ("seven_day", "每週"),
                     ("seven_day_opus", "每週 Opus"), ("seven_day_sonnet", "每週 Sonnet")]
        let windows: [UsageWindow] = names.compactMap { key, name in
            guard let w = root[key] as? [String: Any], let used = double(w["utilization"]) else { return nil }
            return UsageWindow(name: name, usedPercent: used, resetsAt: (w["resets_at"] as? String).flatMap(parseISO))
        }
        guard !windows.isEmpty else { throw UsageError("Claude 沒有回傳額度資料") }
        return Snapshot(plan: nil, windows: windows, fetchedAt: now)
    }

    static func planName(_ oauth: [String: Any]) -> String? {
        let tier = oauth["rateLimitTier"] as? String ?? ""
        if tier.hasSuffix("max_5x") { return "Max 5x" }
        if tier.hasSuffix("max_20x") { return "Max 20x" }
        return (oauth["subscriptionType"] as? String)?.capitalized
    }
}

// MARK: - Gemini（Antigravity / agy：向本機執行中的 language_server 查詢）

/// 只對 127.0.0.1 接受自簽憑證（Antigravity 的本機服務用自簽 TLS）。
final class LocalhostTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

struct GeminiProvider: Provider {
    let id = "gemini", short = "GM", title = "Gemini（Antigravity）"
    let login = LoginAction.openApp(path: "/Applications/Antigravity.app")
    private static let local = URLSession(configuration: .ephemeral, delegate: LocalhostTrust(), delegateQueue: nil)

    func fetch() async throws -> Snapshot {
        let pids = (shell("/usr/bin/pgrep", ["-f", "language_server"]) ?? "").split(separator: "\n").map(String.init)
        for pid in pids {
            guard let command = shell("/bin/ps", ["-o", "command=", "-p", pid]),
                  let csrf = Self.argument("--csrf_token", in: command) else { continue }
            let listening = shell("/usr/sbin/lsof", ["-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-Fn"]) ?? ""
            let ports = Set(listening.split(separator: "\n").compactMap { $0.split(separator: ":").last.flatMap { Int($0) } })
            for port in ports.sorted() {
                func call(_ method: String) async -> Any? {
                    let result = try? await http(
                        "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)",
                        method: "POST",
                        headers: ["Connect-Protocol-Version": "1", "X-Codeium-Csrf-Token": csrf],
                        json: ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en"]],
                        session: Self.local, timeout: 4)
                    guard let (status, body) = result, status == 200 else { return nil }
                    return body
                }
                guard let body = await call("GetUserStatus") else { continue }
                var snapshot = try Self.parse(body)
                // 額度摘要才有「5 小時」與「每週」分開的視窗；舊版 Antigravity 沒有這個介面就沿用逐模型的數字。
                if let summary = await call("RetrieveUserQuotaSummary"), let windows = Self.parseSummary(summary) {
                    snapshot.windows = windows
                }
                return snapshot
            }
        }
        if pids.isEmpty { throw UsageError("Antigravity 未執行", needsLogin: true) }
        throw UsageError("Antigravity 本機服務沒有回應（可能尚未登入）", needsLogin: true)
    }

    static func argument(_ name: String, in command: String) -> String? {
        let parts = command.split(whereSeparator: { $0 == " " || $0 == "=" }).map(String.init)
        guard let i = parts.firstIndex(of: name), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    /// 多個模型共用同一個額度池：以（重置時間, 剩餘比例）歸併成一格。
    static func parse(_ body: Any, now: Date = Date()) throws -> Snapshot {
        guard let status = (body as? [String: Any])?["userStatus"] as? [String: Any] else {
            throw UsageError("Antigravity 回應格式不符")
        }
        let configs = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        var order: [String] = []
        var pools: [String: (labels: [String], remaining: Double, reset: Date?)] = [:]
        for config in configs {
            guard let quota = config["quotaInfo"] as? [String: Any], let reset = quota["resetTime"] as? String else { continue }
            // protobuf 會省略 0：有重置時間但沒有 remainingFraction 代表已用完。
            let fraction = double(quota["remainingFraction"]) ?? 0
            var label = config["label"] as? String ?? "?"
            if let paren = label.range(of: " (") { label = String(label[..<paren.lowerBound]) }
            let key = "\(reset)|\(fraction)"
            if pools[key] == nil { order.append(key); pools[key] = ([], fraction, parseISO(reset)) }
            if !pools[key]!.labels.contains(label) { pools[key]!.labels.append(label) }
        }
        var windows = order.map { key -> UsageWindow in
            let pool = pools[key]!
            let name = pool.labels.prefix(2).joined(separator: " / ") + (pool.labels.count > 2 ? " 等 \(pool.labels.count) 個" : "")
            return UsageWindow(name: name, usedPercent: (1 - pool.remaining) * 100, resetsAt: pool.reset,
                               headline: pool.labels.contains { $0.hasPrefix("Gemini") })
        }
        guard !windows.isEmpty else { throw UsageError("Antigravity 沒有回傳額度資料") }
        windows.sort { $0.headline && !$1.headline }
        let plan = (status["userTier"] as? [String: Any])?["name"] as? String
        let email = status["email"] as? String
        return Snapshot(plan: plan, windows: windows, fetchedAt: now, account: email, accountKey: email)
    }

    /// RetrieveUserQuotaSummary：每個模型群組各有 5 小時與每週額度。沒有可用的視窗就回傳 nil。
    static func parseSummary(_ body: Any) -> [UsageWindow]? {
        guard let groups = ((body as? [String: Any])?["response"] as? [String: Any])?["groups"] as? [[String: Any]] else { return nil }
        var windows: [UsageWindow] = []
        for group in groups {
            let display = group["displayName"] as? String ?? "?"
            let name = display == "Gemini Models" ? "Gemini"
                : display == "Claude and GPT models" ? "Claude / GPT" : display
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let reset = (bucket["resetTime"] as? String).flatMap(parseISO)
                // protobuf 會省略 0：有重置時間但沒有 remainingFraction 代表已用完。
                guard let fraction = double(bucket["remainingFraction"]) ?? (reset != nil ? 0 : nil) else { continue }
                let span: String
                switch bucket["window"] as? String {
                case "5h": span = "5 小時"
                case "weekly": span = "每週"
                case let other?: span = other
                case nil: span = bucket["displayName"] as? String ?? "?"
                }
                windows.append(UsageWindow(name: span, usedPercent: (1 - fraction) * 100, resetsAt: reset,
                                           headline: display.hasPrefix("Gemini"), group: name))
            }
        }
        guard !windows.isEmpty else { return nil }
        // 穩定排序：Gemini 系列（影響狀態列）排前面；同一群組內 5 小時在前、每週在後，跟其他家一致。
        func rank(_ w: UsageWindow) -> Int { w.name == "5 小時" ? 0 : w.name == "每週" ? 1 : 2 }
        return windows.enumerated().sorted { a, b in
            if a.element.headline != b.element.headline { return a.element.headline }
            if a.element.group == b.element.group && rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            return a.offset < b.offset
        }.map(\.element)
    }
}

func fetchAll(_ providers: [Provider]) async -> [String: Result<Snapshot, UsageError>] {
    await withTaskGroup(of: (String, Result<Snapshot, UsageError>).self) { group in
        for p in providers {
            group.addTask {
                do { return (p.id, .success(try await p.fetch())) }
                catch let e as UsageError { return (p.id, .failure(e)) }
                catch { return (p.id, .failure(UsageError("連線失敗：\(error.localizedDescription)"))) }
            }
        }
        var out: [String: Result<Snapshot, UsageError>] = [:]
        for await (id, result) in group { out[id] = result }
        return out
    }
}

let allProviders: [Provider] = [CodexProvider(), ClaudeProvider(), GeminiProvider()]

// MARK: - 登入

/// 產生終端機要執行的 .command 腳本內容。指令是程式內寫死的字串，不含任何外部輸入。
func loginScript(title: String, command: String) -> String {
    """
    #!/bin/zsh -l
    # 由 AIUsageBar 產生：\(title)
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"
    clear
    echo "AIUsageBar：\(title)"
    echo "執行：\(command)"
    echo
    \(command)
    echo
    echo "完成後可以關閉這個視窗，狀態列會在一分鐘內自動更新。"

    """
}

@discardableResult
func performLogin(_ action: LoginAction) -> Bool {
    switch action {
    case .openApp(let path):
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    case .terminal(let title, let command):
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar")
        let url = dir.appendingPathComponent("login-\(command.split(separator: " ").first ?? "cli").command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try loginScript(title: title, command: command).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return false }
        // .command 檔交給終端機開啟：不需要「自動化」權限，也不需要 AppleScript。
        return NSWorkspace.shared.open(url)
    }
}
