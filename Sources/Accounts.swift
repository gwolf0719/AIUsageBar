import CryptoKit
import Foundation

// 多帳號：每次更新時把 CLI 目前登入的那一份憑證複製一份到本機（權限 0600，跟 CLI 自己的 auth.json 同等級），
// 不在使用中的帳號就用存下來的 access token 唯讀查詢用量；token 過期就顯示最後一次的數字。
// 這些副本永遠不換發 token。只有使用者按「切換」時，才把選定帳號的憑證寫回 CLI 的登入位置。

/// 一份帳號憑證副本。secret：Codex 是 auth.json 全文、Claude 是鑰匙圈裡的 JSON。
struct SavedCredential: Codable, Equatable {
    var key: String
    var email: String
    var secret: String
    /// Claude：~/.claude.json 的 oauthAccount（切換時一起換，CLI 才會顯示正確的帳號）。
    var extra: String? = nil
}

/// 能讀出目前登入、用指定憑證查詢、以及切換帳號的 CLI。
protocol CredentialSource: Sendable {
    func readActive() -> SavedCredential?
    func fetch(_ credential: SavedCredential) async throws -> Snapshot
    func activate(_ credential: SavedCredential) throws
}

/// 一個帳號的公開資料（不含任何 token），存在 accounts.json。
struct AccountRecord: Codable, Equatable {
    var provider: String
    var key: String
    var email: String
    var snapshot: Snapshot?
    var error: String?
    /// 有存憑證副本：可以切換過去，也能在不使用時查詢。
    var hasCredential: Bool
    var lastActive: Date?
}

struct AccountBook: Codable, Equatable {
    var records: [AccountRecord] = []
    /// 每家目前在 CLI 上使用中的帳號 key。
    var active: [String: String] = [:]

    func others(_ provider: String) -> [AccountRecord] {
        records.filter { $0.provider == provider && $0.key != active[provider] }
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    func record(_ provider: String, _ key: String) -> AccountRecord? {
        records.first { $0.provider == provider && $0.key == key }
    }

    mutating func upsert(_ record: AccountRecord) {
        if let i = records.firstIndex(where: { $0.provider == record.provider && $0.key == record.key }) {
            records[i] = record
        } else {
            records.append(record)
        }
    }

    mutating func remove(_ provider: String, _ key: String) {
        records.removeAll { $0.provider == provider && $0.key == key }
    }
}

// MARK: - 本機保存

struct AccountVault {
    var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AIUsageBar/accounts")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    private func url(_ provider: String, _ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        return dir.appendingPathComponent("\(provider)-\(digest).json")
    }

    func load(_ provider: String, _ key: String) -> SavedCredential? {
        guard let data = try? Data(contentsOf: url(provider, key)) else { return nil }
        return try? Self.decoder.decode(SavedCredential.self, from: data)
    }

    /// 內容沒變就不寫，避免每 5 分鐘無意義地重寫。
    func save(_ provider: String, _ credential: SavedCredential) {
        guard load(provider, credential.key) != credential,
              let data = try? Self.encoder.encode(credential) else { return }
        try? writePrivateFile(data, to: url(provider, credential.key).path)
    }

    func delete(_ provider: String, _ key: String) {
        try? FileManager.default.removeItem(at: url(provider, key))
    }

    /// 切換前把會被改寫的設定檔留一份。
    func backup(_ path: String, as name: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        try? writePrivateFile(data, to: dir.appendingPathComponent("backup-\(name)").path)
    }

    var bookURL: URL { dir.appendingPathComponent("accounts.json") }

    func loadBook() -> AccountBook {
        (try? Data(contentsOf: bookURL)).flatMap { try? Self.decoder.decode(AccountBook.self, from: $0) } ?? AccountBook()
    }

    func saveBook(_ book: AccountBook) {
        guard let data = try? Self.encoder.encode(book) else { return }
        try? writePrivateFile(data, to: bookURL.path)
    }
}

// MARK: - 更新與切換

/// 一輪更新：先查使用中的帳號，再用存下的憑證查其他帳號。回傳新的狀態與帳號簿。
func refreshEverything(_ providers: [Provider], states old: [String: ProviderState], book old_book: AccountBook,
                       vault: AccountVault, now: Date = Date()) async -> ([String: ProviderState], AccountBook) {
    let results = await fetchAll(providers)
    var states = old
    var book = old_book

    for p in providers {
        let source = p as? CredentialSource
        let current = source?.readActive()
        if let current { vault.save(p.id, current) }

        switch results[p.id] {
        case .success(let snapshot)?:
            if source is ClaudeProvider, let snapshotKey = snapshot.accountKey, snapshotKey != current?.key {
                states[p.id] = ProviderState(snapshot: old[p.id]?.snapshot.flatMap { $0.accountKey == current?.key ? $0 : nil },
                                             error: "使用中的帳號已變更，稍後會重新查詢")
            } else {
                states[p.id] = ProviderState(snapshot: snapshot, error: nil)
            }
        case .failure(let error)?:
            // 換了帳號（或登出）就不要沿用前一個帳號的舊數字。
            let keep = states[p.id]?.snapshot.flatMap { s in current == nil || s.accountKey == nil || s.accountKey == current?.key ? s : nil }
            states[p.id] = ProviderState(snapshot: keep, error: error.message, needsLogin: error.needsLogin)
        case nil:
            break
        }

        let key = current?.key ?? states[p.id]?.snapshot?.accountKey
        guard let key else {
            if source != nil, current == nil { book.active[p.id] = nil }
            continue
        }
        book.active[p.id] = key
        let state = states[p.id]
        book.upsert(AccountRecord(provider: p.id, key: key,
                                  email: current?.email ?? state?.snapshot?.account ?? key,
                                  snapshot: state?.snapshot ?? book.record(p.id, key)?.snapshot,
                                  error: state?.error, hasCredential: current != nil, lastActive: now))
    }

    // 不在使用中、但有存憑證的帳號：同時查詢。
    let pending: [(Provider & CredentialSource, AccountRecord, SavedCredential)] = providers.flatMap { p -> [(Provider & CredentialSource, AccountRecord, SavedCredential)] in
        guard let source = p as? (Provider & CredentialSource) else { return [] }
        return book.others(p.id).compactMap { r in
            guard r.hasCredential, let c = vault.load(p.id, r.key) else { return nil }
            return (source, r, c)
        }
    }
    let fetched = await withTaskGroup(of: (AccountRecord, Result<Snapshot, UsageError>).self) { group in
        for (source, record, credential) in pending {
            group.addTask {
                do { return (record, .success(try await source.fetch(credential))) }
                catch let e as UsageError { return (record, .failure(e)) }
                catch { return (record, .failure(UsageError("連線失敗：\(error.localizedDescription)"))) }
            }
        }
        var out: [(AccountRecord, Result<Snapshot, UsageError>)] = []
        for await item in group { out.append(item) }
        return out
    }
    for (record, result) in fetched {
        var r = record
        switch result {
        case .success(let snapshot): r.snapshot = snapshot; r.error = nil
        case .failure(let error): r.error = error.message
        }
        book.upsert(r)
    }
    return (states, book)
}

enum SwitchError: LocalizedError {
    case missing(String)
    var errorDescription: String? { if case .missing(let m) = self { return m }; return nil }
}

/// 切換帳號：先把目前登入的憑證存好（之後才切得回來），備份設定檔，再寫入選定帳號。
func switchAccount(_ source: CredentialSource, provider: String, to key: String, vault: AccountVault) throws {
    func perform() throws {
        if let current = source.readActive() { vault.save(provider, current) }
        guard let target = vault.load(provider, key) else { throw SwitchError.missing("找不到這個帳號存下來的登入資料") }
        if let claude = source as? ClaudeProvider { vault.backup(claude.configPath, as: "claude.json") }
        if let codex = source as? CodexProvider { vault.backup(codex.authPath, as: "codex-auth.json") }
        try source.activate(target)
    }
    if source is ClaudeProvider {
        try ClaudeProvider.mutations.withSwitch(perform)
    } else {
        try perform()
    }
}

// MARK: - 小工具

/// 一次換發的租約橫跨網路請求。鎖只用來變更租約，不在持鎖時 await。
final class ClaudeCredentialMutations: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func end() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    func withSwitch(_ work: () throws -> Void) throws {
        guard begin() else { throw SwitchError.missing("Claude 正在更新登入，請稍後再切換帳號") }
        defer { end() }
        try work()
    }
}

/// 同一時間只跑一份工作；進行中再有人要求就等同一份結果。
actor SingleFlight<Value: Sendable> {
    private var inFlight: Task<Value, Error>?

    func run(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// 解 JWT 的 payload（不驗簽，只用來讀 email 與到期時間）。
func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let data = Data(base64Encoded: b64) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// 原子寫入並設成只有本人可讀寫（0600），資料夾 0700。
func writePrivateFile(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

/// 從 `security find-generic-password` 的輸出取屬性，例如 "acct"<blob>="me"。
func keychainAttribute(_ name: String, in output: String) -> String? {
    for line in output.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\"\(name)\"<blob>=\""), t.hasSuffix("\"") else { continue }
        return String(t.dropFirst(name.count + 10).dropLast())
    }
    return nil
}

/// 透過 `security -i` 從 stdin 寫入鑰匙圈：密碼以十六進位傳入，不出現在命令列參數（別的程式用 ps 看不到）。
func keychainWrite(service: String, account: String, secret: String) throws {
    let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
    // security -i 一行有長度上限（實測約 4KB 會被截斷），太長就拒絕，不能寫進半份憑證。
    guard hex.count < 3800 else { throw SwitchError.missing("憑證太長，無法安全寫入鑰匙圈") }
    func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["-i"]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    input.fileHandleForWriting.write(Data("add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n".utf8))
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    // security -i 的結束碼不可靠，寫完讀回比對。
    let back = shell("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"])?
        .trimmingCharacters(in: .newlines)
    guard back == secret else { throw SwitchError.missing("寫入鑰匙圈失敗") }
}
