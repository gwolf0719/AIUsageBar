import Foundation

/// 一個額度視窗（例如 5 小時、每週）。usedPercent 為 0–100。
struct UsageWindow: Codable, Equatable {
    var name: String
    var usedPercent: Double
    var resetsAt: Date?
    /// 是否參與狀態列上的「最緊的那一格」計算。
    var headline: Bool = true
    /// 同一家底下的模型群組（例如 Antigravity 的「Gemini」「Claude / GPT」）；nil 表示只有一組。
    var group: String? = nil

    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    /// 含群組的完整名稱，例如「Gemini 每週」。
    var title: String { group.map { "\($0) \(name)" } ?? name }
}

struct Snapshot: Codable, Equatable {
    var plan: String?
    var windows: [UsageWindow]
    var fetchedAt: Date
    /// 這份資料屬於哪個帳號：email 給人看，accountKey 是穩定識別（同一 email 可能有多個工作區）。
    var account: String? = nil
    var accountKey: String? = nil

    /// 不在使用中的帳號只有舊資料：已經過了重置時間的額度視為已回滿。
    func projected(now: Date = Date()) -> Snapshot {
        var copy = self
        copy.windows = windows.map { w in
            guard let reset = w.resetsAt, reset <= now else { return w }
            var full = w; full.usedPercent = 0; full.resetsAt = nil; return full
        }
        return copy
    }

    /// 狀態列顯示的視窗：headline 視窗中剩餘最少的那個。
    var headline: UsageWindow? {
        windows.filter(\.headline).min { $0.remaining < $1.remaining }
    }

    /// 所有額度視窗中，下一個（還沒過的）重置時間點。
    func nextReset(after now: Date = Date()) -> Date? {
        windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

struct UsageError: Error {
    let message: String
    /// true：使用者重新登入就能解決（儀表板卡片會顯示登入按鈕）。
    let needsLogin: Bool
    init(_ message: String, needsLogin: Bool = false) { self.message = message; self.needsLogin = needsLogin }
}

struct ProviderState {
    var snapshot: Snapshot?
    var error: String?
    var needsLogin = false
}

/// 點選「登入」時要做的事。
enum LoginAction: Sendable {
    /// 開一個終端機視窗執行 CLI 的登入指令（OAuth 會在瀏覽器完成）。
    case terminal(title: String, command: String)
    /// 開啟 app（例如 Antigravity）。
    case openApp(path: String)
}

protocol Provider: Sendable {
    var id: String { get }
    var short: String { get }
    var title: String { get }
    var login: LoginAction { get }
    func fetch() async throws -> Snapshot
}

// MARK: - 格式化

func countdown(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "--" }
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return "已重置" }
    let m = seconds / 60
    if m >= 1440 { return "\(m / 1440)d\(m % 1440 / 60)h" }
    if m >= 60 { return "\(m / 60)h\(m % 60)m" }
    return "\(max(1, m))m"
}

/// 儀表板用的完整寫法：「4 天 13 小時」「4 小時 56 分」「58 分鐘」。
func countdownLong(_ date: Date, now: Date = Date()) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return "已重置" }
    let m = max(1, seconds / 60)
    if m >= 1440 { return m % 1440 / 60 == 0 ? "\(m / 1440) 天" : "\(m / 1440) 天 \(m % 1440 / 60) 小時" }
    if m >= 60 { return m % 60 == 0 ? "\(m / 60) 小時" : "\(m / 60) 小時 \(m % 60) 分" }
    return "\(m) 分鐘"
}

/// 重置的時刻：「今天 21:03」「明天 01:01」「週六 09:04」，一週以上（或同一個星期幾）加日期「11/23 週一 20:01」。
func resetMoment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "zh_TW")
    f.dateFormat = "HH:mm"
    let clock = f.string(from: date)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    if days == 0 { return "今天 \(clock)" }
    if days == 1 { return "明天 \(clock)" }
    f.dateFormat = "EEE"
    let weekday = f.string(from: date).replacingOccurrences(of: "週", with: "")
    if days > 1 && days < 7 { return "週\(weekday) \(clock)" }
    f.dateFormat = "M/d"
    return "\(f.string(from: date)) 週\(weekday) \(clock)"
}

func percentText(_ value: Double) -> String { "\(Int(value.rounded()))%" }

func parseISO(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}

func double(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

// MARK: - 共用 I/O

/// 執行系統內建工具並取回 stdout；失敗回傳 nil。
func shell(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
}

func http(_ url: String, method: String = "GET", headers: [String: String] = [:],
          json: Any? = nil, session: URLSession = .shared, timeout: TimeInterval = 15) async throws -> (Int, Any?) {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
    r.httpMethod = method
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    if let json {
        r.httpBody = try JSONSerialization.data(withJSONObject: json)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, resp) = try await session.data(for: r)
    return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
