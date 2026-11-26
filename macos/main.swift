// Tokenly.app: menu bar panel (and optional desktop widget) showing local token usage,
// API-equivalent cost and subscription limits for Claude Code and Codex CLI. Reads local files only.
import AppKit
import Combine
import ServiceManagement
import SwiftUI

let scanDays = 182 // 90-day range plus its "vs previous" period, and the 13-week activity grid
let refreshSeconds: TimeInterval = 300
let slotSeconds: TimeInterval = 300 // active time = 5-minute slots with at least one call

// MARK: - Pricing

// USD per 1M tokens: input, output, cache read, default cache write, extended cache write.
// Keep in sync with PRICES in tokenly.py (tests/test_prices.py checks this).
let defaultPrices: [String: [Double]] = [
    "claude-fable-5-2": [8, 40, 0.20, 10, 16],
    "claude-opus-5-5": [4, 20, 0.20, 5, 8],
    "claude-sonnet-5-5": [2, 10, 0.10, 2.5, 4],
    "claude-haiku-5-5": [0.10, 0.50, 0.01, 0.125, 0.20],
    "claude-opus-4-8": [5, 25, 0.50, 6.25, 10],
    "gpt-6.2-astra": [8, 40, 0.40, 10, 20],
    "gpt-6.2-sol": [2, 10, 0.10, 2.5, 5],
    "gpt-6.1-sol": [2, 10, 0.10, 2.5, 2.5],
]
let contextPricedCodexModels: Set<String> = ["gpt-6.2-astra", "gpt-6.2-sol"]

/// User overrides and additions, shared with the CLI.
let pricesOverrideURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/tokenly/prices.json")

func loadPrices() -> [String: [Double]] {
    var p = defaultPrices
    if let data = try? Data(contentsOf: pricesOverrideURL),
       let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (k, v) in d where !k.hasPrefix("_") {
            if let a = v as? [NSNumber], a.count == 5 { p[k.lowercased()] = a.map { $0.doubleValue } }
        }
    }
    return p
}

/// Opens the override file in TextEdit, creating it from the current table first.
func openPricesFile() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: pricesOverrideURL.path) {
        try? fm.createDirectory(at: pricesOverrideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d: [String: Any] = ["_comment": "USD per 1M tokens: input, output, cache read, default cache write, extended cache write. Used by Tokenly app and CLI."]
        for (k, v) in loadPrices() { d[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: pricesOverrideURL)
        }
    }
    NSWorkspace.shared.open([pricesOverrideURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration())
}

/// One name per underlying model: drops router prefixes, context tags, date snapshots and
/// (when that yields a priced model) reasoning-effort suffixes.
func normalizeModel(_ raw: String, _ known: [String: [Double]]) -> String {
    var m = raw.lowercased()
    if let r = m.firstIndex(of: "[") { m = String(m[..<r]) }
    if let s = m.lastIndex(of: "/") { m = String(m[m.index(after: s)...]) }
    for p in ["global.anthropic.", "us.anthropic.", "eu.anthropic.", "apac.anthropic.", "anthropic."] where m.hasPrefix(p) {
        m.removeFirst(p.count)
    }
    m = m.replacingOccurrences(of: #"-v\d+(:\d+)?$"#, with: "", options: .regularExpression)
    m = m.replacingOccurrences(of: #"[-@]\d{8}$"#, with: "", options: .regularExpression)
    if known[m] == nil {
        let s = m.replacingOccurrences(of: #"-(minimal|low|medium|high|xhigh|max)$"#, with: "", options: .regularExpression)
        if known[s] != nil { m = s }
    }
    return m
}

// Billing provider, derived from the model name; the tool (Claude Code, Codex) is just the log source.
let providers: [(name: String, color: Color)] = [
    ("Anthropic", Color(red: 0.85, green: 0.47, blue: 0.34)),
    ("OpenAI", Color(red: 0.33, green: 0.72, blue: 0.60)),
    ("Google", Color(red: 0.40, green: 0.62, blue: 1.0)),
    ("Other", Color.gray),
]
func providerOf(_ model: String) -> String {
    let m = model.lowercased()
    if m.hasPrefix("claude") { return "Anthropic" }
    if m.hasPrefix("gpt") || m.hasPrefix("codex") || m.range(of: #"^o\d"#, options: .regularExpression) != nil { return "OpenAI" }
    if m.hasPrefix("gemini") { return "Google" }
    return "Other"
}
func providerColor(_ p: String) -> Color { providers.first { $0.name == p }?.color ?? .gray }

// MARK: - Data

struct Row {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0, saved = 0.0, calls = 0.0
    var tokens: Double { input + output + cacheRead + cacheWrite }
    mutating func add(_ r: Row) {
        input += r.input; output += r.output; cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite; cost += r.cost; saved += r.saved; calls += r.calls
    }
}

let thisMac = "This Mac"

/// Usage of one model in one project during one local hour (other devices: one local day).
struct Entry {
    let hour: Date, day: Date, tool: String, model: String, project: String
    var device = thisMac
    var row = Row()
    var slots = Set<Int>() // 5-minute slots with at least one call, for active time
    var usageByTime: [Date: Row] = [:] // split an hour when a plan resets partway through it
    var provider: String { providerOf(model) }
    var isCodex: Bool { tool.localizedCaseInsensitiveContains("Codex") }

    func clippedHour(from: Date, to: Date) -> Entry? {
        let end = hour.addingTimeInterval(3600)
        guard from < to && hour < to && end > from else { return nil }
        if (hour >= from && end <= to) || usageByTime.isEmpty { return hour >= from ? self : nil }
        var result = self
        result.row = Row()
        result.slots = []
        for (at, usage) in usageByTime where at >= from && at < to {
            result.row.add(usage)
            result.slots.insert(Int(at.timeIntervalSince1970 / slotSeconds))
        }
        return result.row.calls > 0 ? result : nil
    }
}

/// One subscription limit window, e.g. "7d" at 88%.
struct QuotaMeter: Identifiable {
    let label: String, percent: Double, resetsAt: Date?
    var window: TimeInterval? = nil // window length, for pace
    var recorded: Double? = nil // the tool's last recorded %, when `percent` is an estimate for now
    var perFull: Double? = nil // API-price cost of 100% of this limit
    var model: String? = nil // a per-model cap (e.g. "fable"): only that model's usage counts toward it
    var ofWeekly: Double? = nil // per-model cap: points of the all-models 7d limit this model has used
    var spent: Double? = nil // API-price cost so far in this window, when it isn't perFull × percent
    var id: String { label }
    /// Share of the window that has passed (0...1), when known.
    var elapsed: Double? {
        guard let w = window, w > 0, let r = resetsAt else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSinceNow / w))
    }
    /// Usage at reset if the current pace continues.
    var projected: Double? { elapsed.flatMap { $0 > 0.05 ? percent / $0 : nil } }
}

/// Subscription usage as last recorded locally by the tool itself.
struct Quota: Identifiable {
    let product: String, plan: String?
    var meters: [QuotaMeter]
    let asOf: Date?
    var source = "" // where the reading came from, shown in the card
    var resetCredits: Int? = nil
    var id: String { product }
    var peak: Double { meters.map { $0.percent }.max() ?? 0 }

    func active(at now: Date = Date()) -> Quota? {
        var reading = self
        reading.meters = meters.filter { ($0.resetsAt ?? .distantFuture) > now }
        return reading.meters.isEmpty ? nil : reading
    }

    static func newestActive(_ readings: Quota?...) -> Quota? {
        let now = Date()
        return readings.compactMap { $0?.active(at: now) }.max { ($0.asOf ?? .distantPast) < ($1.asOf ?? .distantPast) }
    }
}

struct Report {
    var entries: [Entry] = []
    var unpriced: Set<String> = []
    var quotas: [Quota] = []
    var updated = Date()
    var otherDevicesStatus = "" // why other devices are missing, when the import is on
    var codexHistoryStatus = ""
    var loadingCodexHistory = false
    var quotaReadErrors: [String: String] = [:]
    var readings: [QuotaReading] = []
    var codexResetStart: Date?
    var codexResetRemote: [Entry]? // requested from the reset instant, already clipped by Vibe Usage

    var devices: [String] { Array(Set(entries.map { $0.device })).sorted { $0 == thisMac ? true : $1 == thisMac ? false : $0 < $1 } }
    var firstDay: Date? { entries.map { $0.day }.min() }

    /// Entries whose hour lies in [from, to).
    func entries(from: Date, to: Date) -> [Entry] { entries.filter { $0.hour >= from && $0.hour < to } }
    func total(from: Date, to: Date) -> Row { entries(from: from, to: to).reduce(into: Row()) { $0.add($1.row) } }
    var fullestQuota: Quota? { quotas.max { $0.peak < $1.peak } }

    func codexUsageSinceReset(to end: Date) -> [Entry] {
        guard let start = codexResetStart, start < end else { return [] }
        let local = entries.compactMap { e in
            e.device == thisMac && e.isCodex ? e.clippedHour(from: start, to: end) : nil
        }
        return local + (codexResetRemote ?? []).filter { $0.hour < end }
    }

    /// Made-up but realistic data for screenshots (`TOKENLY_DEMO=1`); never mixed with real logs.
    static func demo() -> Report {
        var rng = SystemRandomNumberGenerator()
        var entries: [Entry] = []
        let models: [(String, String, Double, Double)] = [ // tool, model, $ per 1K-call hour, share
            ("Claude Code", "claude-opus-5-5", 9.0, 0.5), ("Claude Code", "claude-sonnet-5-5", 3.0, 0.25), ("Codex", "gpt-6.1-sol", 4.0, 0.25)]
        let projects = ["webapp", "api-server", "docs-site", "infra"]
        for d in 0..<120 {
            let day = daysAgo(d)
            let weekday = cal.component(.weekday, from: day)
            let dayScale = (weekday == 1 || weekday == 7 ? 0.25 : 1.0) * (1.0 + Double(120 - d) / 60) * Double.random(in: 0.6...1.4, using: &rng)
            for h in 9...22 where Double.random(in: 0...1, using: &rng) < 0.7 {
                let hour = cal.date(byAdding: .hour, value: h, to: day)!
                if hour > Date() { continue }
                for (tool, model, rate, share) in models {
                    let cost = rate * share * dayScale * Double.random(in: 0.3...1.7, using: &rng)
                    let tokens = cost / 0.25 * 1e6 * 0.9
                    let row = Row(input: tokens * 0.002, output: tokens * 0.01, cacheRead: tokens * 0.95, cacheWrite: tokens * 0.038,
                                  cost: cost, saved: cost * 4.5, calls: (cost * 12).rounded())
                    var e = Entry(hour: hour, day: day, tool: tool, model: model, project: projects[(h + d) % projects.count], row: row)
                    e.slots = Set((0..<Int.random(in: 4...12, using: &rng)).map { Int(hour.timeIntervalSince1970 / slotSeconds) + $0 })
                    entries.append(e)
                }
            }
        }
        let claudeReset = Date().addingTimeInterval(2.2 * 86400), codexReset = Date().addingTimeInterval(4.1 * 86400)
        let quotas = [
            Quota(product: "Claude", plan: "Max", meters: [QuotaMeter(label: "7d", percent: 64, resetsAt: claudeReset, window: 7 * 86400)],
                  asOf: Date(), source: "live"),
            Quota(product: "Codex", plan: "Pro", meters: [QuotaMeter(label: "7d", percent: 38, resetsAt: codexReset, window: 7 * 86400)],
                  asOf: Date(), source: "live", resetCredits: 2),
        ]
        // Eight weeks of readings; Codex gets a mid-week reset in two of them.
        var readings: [QuotaReading] = []
        for (product, reset, resetWeeks) in [("Claude", claudeReset, Set<Int>()), ("Codex", codexReset, Set([2, 5]))] {
            for k in 0..<8 {
                let end = reset.addingTimeInterval(-Double(k) * 7 * 86400), start = end.addingTimeInterval(-7 * 86400)
                var pct = 0.0
                for step in 1...12 {
                    let at = start.addingTimeInterval(Double(step) * 7 * 86400 / 13)
                    if at > Date() { break }
                    pct += Double.random(in: 5...11, using: &rng)
                    if resetWeeks.contains(k) && step == 7 { pct = 4 }
                    readings.append(QuotaReading(product: product, label: "7d", percent: min(pct, 99), resetsAt: end, window: 7 * 86400, at: at))
                }
            }
        }
        var r = Report(entries: entries, unpriced: [], quotas: quotas)
        r.readings = readings
        r.quotas = estimateQuotas(r)
        r.codexResetStart = codexReset.addingTimeInterval(-7 * 86400)
        r.codexResetRemote = []
        return r
    }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
let cal = Calendar.current
func today() -> Date { cal.startOfDay(for: Date()) }
func tomorrow() -> Date { cal.date(byAdding: .day, value: 1, to: today())! }
func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today())! }
/// One plan-limit reading as a tool reported it: e.g. Codex 7d at 42% at 08:19, resetting Nov 19.
struct QuotaReading: Codable, Hashable {
    let product: String, label: String, percent: Double
    let resetsAt: Date?, window: Double, at: Date
}

struct LimitReset {
    let at: Date
    var previousEnd: Date? = nil // present when the reset changed the plan's schedule
}

/// Detect a usage drop on the same schedule or a new window that started before the old one ended.
func limitResets(_ readings: [QuotaReading]) -> [LimitReset] {
    let rs = readings.filter { $0.resetsAt != nil }.sorted { $0.at < $1.at }
    var out: [LimitReset] = []
    for (p, c) in zip(rs, rs.dropFirst()) {
        guard let previousEnd = p.resetsAt, let end = c.resetsAt else { continue }
        let start = end.addingTimeInterval(-c.window)
        if c.window > 0 && end > previousEnd && start >= p.at && start <= c.at && start < previousEnd {
            out.append(LimitReset(at: start, previousEnd: previousEnd))
        } else if abs(end.timeIntervalSince(previousEnd)) < 60 && c.at < previousEnd && c.percent < p.percent - 3 {
            out.append(LimitReset(at: c.at))
        }
    }
    return out
}

func limitStart(_ meter: QuotaMeter, product: String, asOf: Date, readings: [QuotaReading]) -> Date? {
    guard let end = meter.resetsAt, let length = meter.window, length > 0 else { return nil }
    let from = end.addingTimeInterval(-length)
    guard from <= asOf && end > asOf else { return nil }
    return limitResets(readings.filter { $0.product == product && $0.label == meter.label })
        .map(\.at).filter { $0 >= from && $0 <= asOf }.max() ?? from
}

/// One past or current 7-day window of a plan.
struct PlanWeek: Identifiable {
    let start: Date, end: Date, cost: Double?, resets: Int, peak: Double?
    let hasUnpricedUsage: Bool
    let perFull: Double?   // what 100% was worth this week, when readings allow
    var id: Date { start }
}

/// Weekly windows with cost, resets and the week's own 100% value. A reset that moves the
/// schedule ends the preceding window early, preserving its original start.
func planWeeks(_ r: Report, _ product: String, weeks: Int = 8) -> [PlanWeek] {
    let rs = r.readings.filter { $0.product == product && $0.label == "7d" }
    guard let anchor = rs.filter({ $0.resetsAt != nil }).max(by: { $0.at < $1.at })?.resetsAt else { return [] }
    let resets = limitResets(rs), now = Date(), week: TimeInterval = 7 * 86400
    let reportedEnds = Set(rs.compactMap(\.resetsAt)).sorted()
    let productEntries = r.entries.filter { $0.tool.localizedCaseInsensitiveContains(product) }
    var end = anchor, scheduledEnd = anchor
    var result: [PlanWeek] = []
    for _ in 0..<weeks {
        let start = scheduledEnd.addingTimeInterval(-week)
        let until = min(end, now)
        let entries = productEntries.filter { entry in
            if entry.device == thisMac { return entry.clippedHour(from: start, to: until) != nil }
            let dayEnd = cal.date(byAdding: .day, value: 1, to: entry.day)!
            return max(start, entry.day) < min(until, dayEnd)
        }
        let cost = entries.isEmpty ? nil : productCost(entries, product, from: start, to: until)
        let hasUnpricedUsage = entries.contains { $0.device == thisMac && r.unpriced.contains($0.model) }
        let inWeek = rs.filter { $0.at >= start && $0.at < end }
        let weekResets = resets.filter { $0.at >= start && $0.at < end }.map(\.at)
        // 100% value: in the stretch since the last reset before a reading, cost ÷ % at that reading.
        var perFull: Double?
        if !hasUnpricedUsage, let best = inWeek.filter({ $0.percent >= 5 }).max(by: { $0.percent < $1.percent }) {
            let segStart = max(start, weekResets.filter { $0 <= best.at }.max() ?? start)
            let c = productCost(entries, product, from: segStart, to: best.at)
            if c > 0 { perFull = c / best.percent * 100 }
        }
        if cost != nil || !inWeek.isEmpty || !weekResets.isEmpty {
            result.append(PlanWeek(start: start, end: end, cost: cost, resets: weekResets.count,
                                   peak: inWeek.map { $0.percent }.max(), hasUnpricedUsage: hasUnpricedUsage, perFull: perFull))
        }
        if let previousEnd = resets.last(where: { $0.at == start && $0.previousEnd != nil })?.previousEnd {
            end = start
            scheduledEnd = previousEnd
        } else {
            // A new period can start with the next request, leaving a gap after the previous deadline.
            end = reportedEnds.last { $0 <= start && $0 > start.addingTimeInterval(-week) } ?? start
            scheduledEnd = end
        }
    }
    return result
}

/// Keeps every plan reading Tokenly has seen, so weeks stay measurable after the tools' logs are gone.
final class ReadingStore {
    private(set) var all: [QuotaReading] = []
    private var loaded = false
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tokenly/plan-readings.json")

    func merge(_ new: [QuotaReading]) -> [QuotaReading] {
        if !loaded {
            loaded = true
            if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([QuotaReading].self, from: d) { all = a }
        }
        var seen = Set(all.map { "\($0.product)|\($0.label)|\(Int($0.at.timeIntervalSince1970))" })
        var changed = false
        for x in new where seen.insert("\(x.product)|\(x.label)|\(Int(x.at.timeIntervalSince1970))").inserted {
            all.append(x); changed = true
        }
        if changed {
            all.sort { $0.at < $1.at }
            if all.count > 50_000 { all.removeFirst(all.count - 50_000) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(all) { try? d.write(to: url) }
        }
        return all
    }
}

/// API-price cost of one product's usage in [from, to), across every device (plan limits are per account).
/// Other devices report whole days, so a day that only partly overlaps counts in proportion.
func productCost(_ entries: [Entry], _ product: String, from: Date, to: Date = Date(), model: String? = nil) -> Double {
    let key = product.lowercased(), now = Date()
    return entries.reduce(0) { acc, e in
        guard e.tool.lowercased().contains(key), model.map({ e.model.lowercased().contains($0) }) ?? true else { return acc }
        if e.device == thisMac { return acc + (e.clippedHour(from: from, to: to)?.row.cost ?? 0) }
        let dayEnd = min(cal.date(byAdding: .day, value: 1, to: e.day)!, now)
        let length = dayEnd.timeIntervalSince(e.day)
        let overlap = max(0, min(dayEnd, to).timeIntervalSince(max(e.day, from)))
        return length > 0 ? acc + e.row.cost * overlap / length : acc
    }
}

/// The tools record plan usage only when they run on this Mac, so a reading goes stale while you work
/// elsewhere. Estimate it for now: last recorded % plus usage since, at the window's cost-per-% rate.
private func with(_ m: QuotaMeter, percent: Double) -> QuotaMeter {
    var out = QuotaMeter(label: m.label, percent: min(100, percent), resetsAt: m.resetsAt, window: m.window,
                         recorded: m.recorded, perFull: m.perFull, model: m.model, ofWeekly: m.ofWeekly)
    out.spent = m.spent.map { $0 * percent / m.percent }
    return out
}

/// Claude's plan limits, from a live get_usage reply's `rate_limits` or the copy in ~/.claude.json. Besides the
/// classic windows, plans can cap a model on its own (`limits` entries of kind weekly_scoped, or `model_scoped`),
/// and `weekly_scoped_shares` says how many points of the all-models week that model used.
func claudeMeters(_ u: [String: Any], now: Date = Date()) -> [QuotaMeter] {
    let week: TimeInterval = 7 * 86400
    func live(_ reset: Date?) -> Bool { reset.map { $0 >= now } ?? true }
    var meters = [("five_hour", "5h", 5 * 3600.0), ("seven_day", "7d", week), ("seven_day_opus", "7d Opus", week),
                  ("seven_day_sonnet", "7d Sonnet", week)].compactMap { key, label, window -> QuotaMeter? in
        guard let w = u[key] as? [String: Any], let p = w["utilization"] as? NSNumber else { return nil }
        let reset = parseDate(w["resets_at"])
        return live(reset) ? QuotaMeter(label: label, percent: p.doubleValue, resetsAt: reset, window: window) : nil
    }
    let limits = u["limits"] as? [[String: Any]] ?? []
    func modelName(_ l: [String: Any]) -> String? {
        ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
    }
    let shareList = u["weekly_scoped_shares"] as? [[String: Any]] ?? []
    var shares: [String: Double] = [:]
    for s in shareList {
        guard let i = (s["limit_index"] as? NSNumber)?.intValue, limits.indices.contains(i),
              let name = modelName(limits[i]), let used = s["used_percent_of_weekly"] as? NSNumber else { continue }
        shares[name] = used.doubleValue
    }
    var scoped: [(String, Double, Date?)] = limits.compactMap { l in
        guard l["kind"] as? String == "weekly_scoped", let name = modelName(l), let p = l["percent"] as? NSNumber else { return nil }
        return (name, p.doubleValue, parseDate(l["resets_at"]))
    }
    for s in u["model_scoped"] as? [[String: Any]] ?? [] {
        guard let name = s["display_name"] as? String, let p = s["utilization"] as? NSNumber,
              !scoped.contains(where: { $0.0 == name }) else { continue }
        scoped.append((name, p.doubleValue, parseDate(s["resets_at"])))
    }
    // Some replies leave out `limits`; with one share and one per-model cap there is only one way to pair them.
    if shares.isEmpty, shareList.count == 1, scoped.count == 1,
       let used = shareList[0]["used_percent_of_weekly"] as? NSNumber { shares[scoped[0].0] = used.doubleValue }
    for (name, percent, reset) in scoped where !name.isEmpty && live(reset) && !meters.contains(where: { $0.label == "7d \(name)" }) {
        meters.append(QuotaMeter(label: "7d \(name)", percent: percent, resetsAt: reset, window: week,
                                 model: name.lowercased(), ofWeekly: shares[name]))
    }
    return meters
}

func estimateQuotas(_ r: Report) -> [Quota] {
    r.quotas.map { q in
        Quota(product: q.product, plan: q.plan, meters: q.meters.map { m in
            guard let asOf = q.asOf, m.percent >= 5,
                  let start = limitStart(m, product: q.product, asOf: asOf, readings: r.readings) else { return m }
            let recent = Date().timeIntervalSince(asOf) <= 5 * 60
            let preciseRemote = q.product == "Codex" && start == r.codexResetStart && recent ? r.codexResetRemote : nil
            let before = preciseRemote.map { remote in
                // The live reading and the reset-window query are made together on a refresh.
                productCost(r.entries.filter { $0.device == thisMac }, q.product, from: start, to: asOf)
                    + remote.reduce(0) { $0 + $1.row.cost }
            } ?? productCost(r.entries, q.product, from: start, to: asOf)
            guard before > 0 else { return m }
            let stale = Date().timeIntervalSince(asOf) > 900
            var out = m
            if let model = m.model {
                // A per-model cap counts only that model's usage.
                let spent = productCost(r.entries, q.product, from: start, to: asOf, model: model)
                guard spent > 0 else { return m }
                out.perFull = spent / m.percent * 100
                let after = stale ? productCost(r.entries, q.product, from: asOf, model: model) : 0
                if after > 0 { out.recorded = m.percent; out = with(out, percent: m.percent + after / out.perFull! * 100) }
                return out
            }
            // The all-models week: Claude says how many of its points each capped model used, so each model's
            // usage is priced at its own rate instead of one blended $ per %, which moves whenever the mix does.
            var rates: [(model: String?, perPoint: Double)] = []
            var restCost = before, restPoints = m.percent
            if m.label == "7d" {
                for s in q.meters where s.model != nil && (s.ofWeekly ?? 0) >= 1 {
                    let c = productCost(r.entries, q.product, from: start, to: asOf, model: s.model)
                    guard c > 0 else { continue }
                    rates.append((s.model, c / s.ofWeekly!)); restCost -= c; restPoints -= s.ofWeekly!
                }
            }
            if !rates.isEmpty && (restPoints < 1 || restCost <= 0) { rates = [] }
            let restRate = rates.isEmpty ? before / m.percent : restCost / restPoints
            out.perFull = restRate * 100
            if !rates.isEmpty { out.spent = before }
            if stale {
                var points = 0.0, scopedAfter = 0.0
                for (model, perPoint) in rates {
                    let c = productCost(r.entries, q.product, from: asOf, model: model)
                    points += c / perPoint; scopedAfter += c
                }
                points += (productCost(r.entries, q.product, from: asOf) - scopedAfter) / restRate
                if points > 0 { out.recorded = m.percent; out = with(out, percent: m.percent + points) }
            }
            return out
        }, asOf: q.asOf, source: q.source, resetCredits: q.resetCredits)
    }
}

/// Tooltip for "100% ≈ $": which usage the value is measured on.
func limitWorthHelp(_ m: QuotaMeter, _ q: Quota) -> String {
    if let model = m.model {
        let share = m.ofWeekly.map { " It has used \(Int($0.rounded())) points of the all-models week." } ?? ""
        return "What this \(m.label) cap is worth at API list prices, from \(model.capitalized) usage in this window.\(share)"
    }
    let capped = q.meters.filter { $0.model != nil && $0.ofWeekly != nil }.map { $0.label.replacingOccurrences(of: "7d ", with: "") }
    if m.label == "7d", m.spent != nil, !capped.isEmpty {
        return "What the full week is worth at API list prices if spent on models other than \(capped.joined(separator: ", ")). Claude reports how many points those used, so each model is counted at its own rate."
    }
    return "What this plan's full \(m.label) limit is worth at API list prices, from usage in this window up to the last recorded %"
}

func activeSeconds(_ es: [Entry]) -> Double {
    Double(es.reduce(into: Set<Int>()) { $0.formUnion($1.slots) }.count) * slotSeconds
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()
/// ISO-8601 with or without fractional seconds (any number of digits).
func parseDate(_ v: Any?) -> Date? {
    guard let s = v as? String else { return nil }
    if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return d }
    return isoPlain.date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

/// Parse state of one log file, so a refresh only reads what was appended since the last one.
final class FileState {
    var size: UInt64 = 0, mtime = Date.distantPast, offset: UInt64 = 0
    var buckets: [String: Entry] = [:]
    var unpriced = Set<String>()
    var model = "?", project = "" // Codex: set by turn_context lines, apply to later events
    var rateLimits: (at: Date, value: [String: Any])? // Codex: newest rate_limits seen in this file
    var readings: [QuotaReading] = [] // Codex: every change of a limit's % seen in this file
}

/// Long-lived: keeps per-file results between refreshes and reads files in 1 MiB chunks,
/// so large, growing session logs cost neither repeated full reads nor file-sized memory.
final class Scanner {
    private var files: [String: FileState] = [:]
    private var seenClaude = Set<String>()
    private var prices: [String: [Double]] = [:]
    private var codexHistoryStatus = ""
    private let env = ProcessInfo.processInfo.environment
    private let vibe = VibeImporter()
    private let codexLive = CodexLive()
    private let claudeLive = ClaudeLive()
    var liveClaude = true
    private let readingStore = ReadingStore()
    var liveCodex = true

    /// Other devices' buckets, priced with our table when we know the model.
    func remoteEntries(_ buckets: [VibeImporter.Bucket], excluding host: String?, useBucketTime: Bool = false) -> [Entry] {
        return buckets.compactMap { b in
            guard b.hostname != host, let at = parseDate(b.bucketStart) else { return nil }
            let day = cal.startOfDay(for: at)
            let model = normalizeModel(b.model, prices)
            let i = b.inputTokens ?? 0, o = (b.outputTokens ?? 0) + (b.reasoningOutputTokens ?? 0), cr = b.cachedInputTokens ?? 0
            let w5 = b.cacheCreation5mTokens ?? 0, w1 = b.cacheCreation1hTokens ?? 0
            var r = Row(input: i, output: o, cacheRead: cr, cacheWrite: w5 + w1, cost: b.estimatedCost ?? 0)
            if let p = prices[model] {
                // An imported bucket has no per-request context lengths. Keep the source's estimate when available.
                if !contextPricedCodexModels.contains(model) || p != defaultPrices[model] || b.estimatedCost == nil {
                    r.cost = (i * p[0] + o * p[1] + cr * p[2] + w5 * p[3] + w1 * p[4]) / 1e6
                }
                r.saved = cr * (p[0] - p[2]) / 1e6
            }
            let project = b.project == nil || b.project == "unknown" ? "" : b.project!
            return Entry(hour: useBucketTime ? at : day, day: day, tool: b.source, model: model, project: project,
                         device: b.hostname, row: r)
        }
    }

    func add(_ st: FileState, _ date: Date, _ tool: String, _ rawModel: String, _ project: String,
             _ i: Double, _ o: Double, _ cr: Double, _ cw: Double, _ cw1h: Double = 0) {
        guard i + o + cr + cw > 0, !rawModel.hasPrefix("<") else { return }
        let model = normalizeModel(rawModel, prices)
        let p = prices[model] ?? [0, 0, 0, 0, 0]
        if prices[model] == nil { st.unpriced.insert(model) }
        let longContext = tool == "Codex" && contextPricedCodexModels.contains(model)
            && i + cr + cw > 272_000 && p == defaultPrices[model]
        let inputMultiplier = longContext ? 2.0 : 1.0
        let outputMultiplier = longContext ? 1.5 : 1.0
        let inputCost = i * p[0] + cr * p[2] + (cw - cw1h) * p[3] + cw1h * p[4]
        let cost = (inputCost * inputMultiplier + o * p[1] * outputMultiplier) / 1e6
        let saved = cr * (p[0] - p[2]) * inputMultiplier / 1e6
        let r = Row(input: i, output: o, cacheRead: cr, cacheWrite: cw, cost: cost, saved: saved, calls: 1)
        let hour = cal.dateInterval(of: .hour, for: date)!.start
        let key = "\(hour.timeIntervalSince1970)|\(tool)|\(model)|\(project)"
        if st.buckets[key] == nil {
            st.buckets[key] = Entry(hour: hour, day: cal.startOfDay(for: date), tool: tool, model: model, project: project)
        }
        st.buckets[key]!.row.add(r)
        st.buckets[key]!.slots.insert(Int(date.timeIntervalSince1970 / slotSeconds))
        st.buckets[key]!.usageByTime[date, default: Row()].add(r)
    }

    /// Session files modified since the start of the scan window.
    func jsonl(under dir: String, since: Date, compressed: Bool = false) -> [String] {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [String] = []
        for case let f as URL in e where f.pathExtension == "jsonl" || (compressed && f.lastPathComponent.hasSuffix(".jsonl.zst")) {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod = mod, mod < since { continue }
            out.append(f.path)
        }
        return out
    }

    /// Plain logs are incremental. Compressed rollouts are read once per file revision.
    @discardableResult
    func scan(_ path: String, decoder: String? = nil, matching markers: [Data], _ body: (FileState, Substring) -> Void) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return false }
        let previous = files[path]
        if let previous, size == previous.size && mtime == previous.mtime { return true }
        var st = FileState()
        let h: FileHandle
        var process: Process?
        var decoderFinished: DispatchSemaphore?
        if let decoder {
            let decoderProcess = Process(), output = Pipe()
            let finished = DispatchSemaphore(value: 0)
            decoderProcess.executableURL = URL(fileURLWithPath: decoder)
            decoderProcess.arguments = ["-qdc", "--", path]
            decoderProcess.standardOutput = output
            decoderProcess.standardError = FileHandle.nullDevice
            decoderProcess.terminationHandler = { _ in finished.signal() }
            do { try decoderProcess.run() } catch { return false }
            process = decoderProcess
            decoderFinished = finished
            h = output.fileHandleForReading
        } else {
            guard let file = FileHandle(forReadingAtPath: path) else { return false }
            h = file
            if let previous, previous.offset <= size { st = previous }
            h.seek(toFileOffset: st.offset)
        }
        defer {
            try? h.close()
            if let process, process.isRunning { process.terminate(); decoderFinished?.wait() }
        }

        func consume(_ data: Data) {
            for line in data.split(separator: 0x0A) where markers.contains(where: { line.range(of: $0) != nil }) {
                body(st, String(decoding: line, as: UTF8.self)[...])
            }
        }

        var carry = Data()
        do {
            while let chunk = try autoreleasepool(invoking: { try h.read(upToCount: 1 << 20) }), !chunk.isEmpty {
                carry.append(chunk)
                guard let nl = carry.lastIndex(of: 0x0A) else { continue }
                let complete = carry[carry.startIndex...nl]
                autoreleasepool { consume(complete) }
                st.offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: nl)...])
            }
        } catch { return false }
        if let process, let decoderFinished {
            decoderFinished.wait()
            guard process.terminationStatus == 0 else { return false }
            autoreleasepool { consume(carry) }
        }
        st.size = size
        st.mtime = mtime
        files[path] = st
        return true
    }

    func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    func scanClaude(_ root: String, since: Date) -> [String] {
        let paths = jsonl(under: root + "/projects", since: since)
        let markers = [Data("\"usage\"".utf8)]
        for path in paths {
            scan(path, matching: markers) { st, line in
                guard let d = json(line), let m = d["message"] as? [String: Any],
                      let u = m["usage"] as? [String: Any], let date = parseDate(d["timestamp"]) else { return }
                // the same message can be logged several times, also across session files
                if !seenClaude.insert("\(m["id"] ?? "")|\(d["requestId"] ?? "")").inserted { return }
                let cc = u["cache_creation"] as? [String: Any]
                add(st, date, "Claude Code", m["model"] as? String ?? "?",
                    ((d["cwd"] as? String ?? "") as NSString).lastPathComponent,
                    num(u["input_tokens"]), num(u["output_tokens"]),
                    num(u["cache_read_input_tokens"]), num(u["cache_creation_input_tokens"]),
                    num(cc?["ephemeral_1h_input_tokens"]))
            }
        }
        return paths
    }

    func scanCodex(_ root: String, since: Date, beforeBackfill: () -> Void) -> [String] {
        let logs = ["sessions", "archived_sessions"].flatMap { jsonl(under: root + "/" + $0, since: since, compressed: true).sorted() }
        let plain = logs.filter { !$0.hasSuffix(".zst") }, compressed = logs.filter { $0.hasSuffix(".zst") }
        var seen = Set<String>()
        // The same rollout can be present in both folders or both formats during archiving.
        let paths = (plain + compressed).filter { path in
            let name = (path as NSString).lastPathComponent
            return seen.insert(name.hasSuffix(".zst") ? String(name.dropLast(4)) : name).inserted
        }
        let decoderPaths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            + (env["PATH"] ?? "").split(separator: ":").map { "\($0)/zstd" }
        let decoder = decoderPaths.first(where: FileManager.default.isExecutableFile(atPath:))
        let markers = [Data("\"turn_context\"".utf8), Data("\"token_count\"".utf8)]
        var needsDecoder = false, unreadable = false, startedBackfill = false
        for path in paths {
            let isCompressed = path.hasSuffix(".zst")
            if isCompressed && decoder == nil { needsDecoder = true; continue }
            if isCompressed && files[path] == nil && !startedBackfill {
                beforeBackfill()
                startedBackfill = true
            }
            let read = scan(path, decoder: isCompressed ? decoder : nil, matching: markers) { st, line in
                guard let d = json(line), let p = d["payload"] as? [String: Any] else { return }
                if d["type"] as? String == "turn_context" {
                    if let m = p["model"] as? String { st.model = m }
                    if let c = p["cwd"] as? String { st.project = (c as NSString).lastPathComponent }
                } else if p["type"] as? String == "token_count", let date = parseDate(d["timestamp"]) {
                    if let u = (p["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] {
                        let c = num(u["cached_input_tokens"]), w = num(u["cache_write_input_tokens"])
                        add(st, date, "Codex", st.model, st.project, num(u["input_tokens"]) - c - w,
                            num(u["output_tokens"]), c, w)
                    }
                    if let rl = p["rate_limits"] as? [String: Any] {
                        for k in ["primary", "secondary"] {
                            guard let w = rl[k] as? [String: Any], let pct = w["used_percent"] as? NSNumber else { continue }
                            let mins = num(w["window_minutes"]), label = Scanner.windowLabel(minutes: mins)
                            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                            if let last = st.readings.last(where: { $0.label == label }), last.percent == pct.doubleValue, last.resetsAt == reset { continue }
                            st.readings.append(QuotaReading(product: "Codex", label: label, percent: pct.doubleValue,
                                                            resetsAt: reset, window: mins * 60, at: date))
                        }
                    }
                    if let rl = p["rate_limits"] as? [String: Any], date >= (st.rateLimits?.at ?? .distantPast) {
                        st.rateLimits = (date, rl)
                    }
                }
            }
            if !read { unreadable = true }
        }
        if needsDecoder {
            codexHistoryStatus = "Install zstd to read compressed Codex logs"
        } else {
            codexHistoryStatus = unreadable ? "Some Codex logs could not be read" : ""
        }
        return paths
    }

    // MARK: quotas

    static func windowLabel(minutes: Double) -> String {
        minutes == 10080 ? "7d" : minutes.truncatingRemainder(dividingBy: 1440) == 0
            ? "\(Int(minutes / 1440))d" : "\(Int((minutes / 60).rounded()))h"
    }

    /// Codex live reading saved by the Vibe Usage app (~/.vibe-usage/codex-rate-limits.json): %, reset time,
    /// plan and reset credits only, no credentials. Fresher than Codex's own logs whenever Codex hasn't
    /// run on this Mac recently, because Vibe Usage asks OpenAI directly.
    func vibeCodexQuota() -> Quota? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.vibe-usage/codex-rate-limits.json"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = parseDate(d["fetchedAt"]) else { return nil }
        let notEnforced = d["fiveHourNotEnforced"] as? Bool ?? false
        let meters = [("fiveHour", "5h"), ("sevenDay", "7d")].compactMap { key, label -> QuotaMeter? in
            guard let w = d[key] as? [String: Any], w["utilization"] is NSNumber, !(key == "fiveHour" && notEnforced) else { return nil }
            let reset = parseDate(w["resetsAt"])
            if let reset = reset, reset < Date() { return nil }
            return QuotaMeter(label: label, percent: num(w["utilization"]), resetsAt: reset,
                              window: (w["windowDuration"] as? NSNumber)?.doubleValue ?? (label == "5h" ? 18000 : 604800))
        }
        if meters.isEmpty { return nil }
        return Quota(product: "Codex", plan: d["planLabel"] as? String, meters: meters, asOf: at,
                     source: "Vibe Usage cache", resetCredits: (d["resetCreditsCount"] as? NSNumber)?.intValue)
    }

    /// Codex: prefer a successful direct read, then the newest usable saved reading.
    func codexQuota(forceRefresh: Bool) -> Quota? {
        let direct = liveCodex ? codexLive.quota(forceRefresh: forceRefresh) : nil
        if codexLive.status.isEmpty, let live = direct?.active() { return live }
        return Quota.newestActive(direct, vibeCodexQuota(), codexLogQuota())
    }

    private func codexLogQuota() -> Quota? {
        guard let (at, rl) = files.values.compactMap({ $0.rateLimits }).max(by: { $0.at < $1.at }) else { return nil }
        let meters = ["primary", "secondary"].compactMap { k -> QuotaMeter? in
            guard let w = rl[k] as? [String: Any] else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reset = reset, reset < Date() { return nil }
            return QuotaMeter(label: Scanner.windowLabel(minutes: num(w["window_minutes"])),
                              percent: num(w["used_percent"]), resetsAt: reset, window: num(w["window_minutes"]) * 60)
        }.sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        if meters.isEmpty { return nil }
        return Quota(product: "Codex", plan: (rl["plan_type"] as? String)?.capitalized, meters: meters, asOf: at,
                     source: "Codex logs on this Mac")
    }

    /// Claude: prefer a successful direct read, then the newest usable saved reading.
    func claudeQuota() -> Quota? {
        guard liveClaude else { return cachedClaudeQuota() }
        let direct = claudeLive.quota()
        if claudeLive.status.isEmpty {
            if direct == nil { return nil } // Claude Code confirmed this login has no subscription limits.
            if let live = direct?.active() { return live }
        }
        return Quota.newestActive(direct, cachedClaudeQuota())
    }

    private func cachedClaudeQuota() -> Quota? {
        let dir = env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory()
        guard let data = FileManager.default.contents(atPath: dir + "/.claude.json"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = d["cachedUsageUtilization"] as? [String: Any],
              let u = cache["utilization"] as? [String: Any] else { return nil }
        let meters = claudeMeters(u)
        if meters.isEmpty { return nil }
        let asOf = (cache["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Quota(product: "Claude", plan: nil, meters: meters, asOf: asOf, source: "Claude Code on this Mac")
    }

    private func localReport(since: Date) -> Report {
        var merged: [String: Entry] = [:]
        var unpriced = Set<String>()
        for st in files.values {
            unpriced.formUnion(st.unpriced)
            for (k, e) in st.buckets where e.day >= since {
                if merged[k] == nil { merged[k] = e } else {
                    merged[k]!.row.add(e.row)
                    merged[k]!.slots.formUnion(e.slots)
                    for (at, usage) in e.usageByTime { merged[k]!.usageByTime[at, default: Row()].add(usage) }
                }
            }
        }
        return Report(entries: Array(merged.values), unpriced: unpriced)
    }

    func run(otherDevices: Bool = false, forceCodexRefresh: Bool = false, includeCodexReset: Bool = false,
             publishBeforeBackfill: ((Report) -> Void)? = nil) -> Report {
        let p = loadPrices()
        if p != prices { prices = p; files = [:]; seenClaude = [] } // costs are computed while parsing
        let since = daysAgo(scanDays - 1)
        let claudePaths = scanClaude(env["CLAUDE_CONFIG_DIR"] ?? "~/.claude", since: since)
        let codexPaths = scanCodex(env["CODEX_HOME"] ?? "~/.codex", since: since) {
            guard let publishBeforeBackfill else { return }
            var partial = localReport(since: since)
            partial.loadingCodexHistory = true
            publishBeforeBackfill(partial)
        }
        let alive = Set(claudePaths + codexPaths)
        files = files.filter { alive.contains($0.key) } // forget files that aged out
        let codex = codexQuota(forceRefresh: forceCodexRefresh)
        var report = localReport(since: since)
        report.quotas = [claudeQuota(), codex].compactMap { $0 }
        report.codexHistoryStatus = codexHistoryStatus
        if liveClaude && !claudeLive.status.isEmpty { report.quotaReadErrors["Claude"] = claudeLive.status }
        if liveCodex && !codexLive.status.isEmpty { report.quotaReadErrors["Codex"] = codexLive.status }
        if otherDevices {
            let (buckets, host) = vibe.buckets()
            report.entries += remoteEntries(buckets, excluding: host)
            report.otherDevicesStatus = vibe.status
        }
        var fresh = files.values.flatMap { $0.readings }
        for q in report.quotas {
            guard let at = q.asOf else { continue }
            fresh += q.meters.map { QuotaReading(product: q.product, label: $0.label, percent: $0.percent,
                                                 resetsAt: $0.resetsAt, window: $0.window ?? 0, at: at) }
        }
        report.readings = readingStore.merge(fresh)
        if let codex, let at = codex.asOf,
           let weekly = codex.meters.first(where: { $0.label == "7d" }),
           let end = weekly.resetsAt, end > Date(),
           let start = limitStart(weekly, product: codex.product, asOf: at, readings: report.readings) {
            report.codexResetStart = start
            if otherDevices && includeCodexReset,
               let (buckets, host) = vibe.buckets(since: start, force: forceCodexRefresh) {
                report.codexResetRemote = remoteEntries(buckets, excluding: host, useBucketTime: true).filter(\.isCodex)
            }
        }
        report.quotas = estimateQuotas(report)
        return report
    }
}

// MARK: - Other devices (optional)

/// Opt-in, read-only: usage of the user's other devices from their own Vibe Usage account (vibecafe.ai),
/// using the key the Vibe Usage app already stored in ~/.vibe-usage/config.json. Nothing is uploaded.
/// History older than `recentDays` is fetched once in 30-day chunks and cached on disk; recent days come
/// from the fresher `days=` query, refetched at most every 15 minutes.
final class VibeImporter {
    struct Bucket: Codable {
        let bucketStart: String, hostname: String, source: String, model: String
        let project: String?
        let inputTokens, outputTokens, reasoningOutputTokens, cachedInputTokens: Double?
        let cacheCreation5mTokens, cacheCreation1hTokens, estimatedCost: Double?
        var day: Date? { parseDate(bucketStart).map { cal.startOfDay(for: $0) } }
    }
    private struct Cache: Codable { var account: String; var historyUntil: String?; var history: [Bucket] }
    private struct Response: Decodable { let buckets: [Bucket]? }

    private(set) var status = ""
    private var recent: [Bucket] = []
    private var lastRecent = Date.distantPast
    private var cache: Cache?
    private var resetUsage: (start: Date, account: String?, at: Date, buckets: [Bucket]?)?
    private let recentDays = 8
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tokenly/vibe-history.json")
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    struct Config { let url: String, key: String, host: String? }
    static func config() -> Config? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.vibe-usage/config.json"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = d["apiKey"] as? String, !key.isEmpty else { return nil }
        return Config(url: d["apiUrl"] as? String ?? "https://vibecafe.ai", key: key, host: d["hostname"] as? String)
    }

    private func get(_ params: [String: String], _ cfg: Config) -> [Bucket]? {
        guard var c = URLComponents(string: cfg.url + "/api/usage") else { return nil }
        c.queryItems = params.merging(["tz": TimeZone.current.identifier]) { a, _ in a }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 30)
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.setValue("Tokenly", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var out: [Bucket]?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err = err { self.status = "Couldn't reach Vibe Usage (\(err.localizedDescription))"; return }
            guard code == 200, let data = data else {
                self.status = code == 401 ? "Vibe Usage rejected the key — relink in the Vibe Usage app" : "Vibe Usage answered HTTP \(code)"
                return
            }
            out = (try? JSONDecoder().decode(Response.self, from: data))?.buckets ?? []
        }.resume()
        done.wait()
        return out
    }

    /// Vibe Usage applies the exact cutoff before grouping into its hourly or daily buckets.
    func buckets(since start: Date, force: Bool) -> ([Bucket], String?)? {
        guard let cfg = Self.config() else { return nil }
        let account = cache?.account
        if !force, let resetUsage, resetUsage.start == start, resetUsage.account == account,
           Date().timeIntervalSince(resetUsage.at) < 900 {
            return resetUsage.buckets.map { ($0, cfg.host) }
        }
        let originalStatus = status
        defer { status = originalStatus }
        let buckets = get(["from": isoFrac.string(from: start)], cfg)
        resetUsage = (start, account, Date(), buckets)
        return buckets.map { ($0, cfg.host) }
    }

    /// Buckets of every device on the account (callers drop this Mac's own).
    func buckets() -> (buckets: [Bucket], host: String?) {
        guard let cfg = VibeImporter.config() else { status = "Vibe Usage isn't linked on this Mac"; return ([], nil) }
        let account = String(cfg.key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
        if cache == nil, let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d), c.account == account {
            cache = c
        }
        if cache?.account != account { cache = Cache(account: account, historyUntil: nil, history: []) }
        let historyEnd = daysAgo(recentDays) // history: days <= historyEnd; recent: later days
        var start: Date?
        if let u = cache!.historyUntil, let d = dayFmt.date(from: u) {
            start = cal.date(byAdding: .day, value: 1, to: d)
        } else if let all = get(["from": "2015-01-01", "to": dayFmt.string(from: today())], cfg) {
            start = all.compactMap { $0.day }.min() ?? historyEnd
        }
        var changed = false
        while let s = start, s <= historyEnd {
            let stop = min(cal.date(byAdding: .day, value: 29, to: s)!, historyEnd)
            guard let b = get(["from": dayFmt.string(from: s), "to": dayFmt.string(from: stop)], cfg) else { break }
            cache!.history += b.filter { ($0.day ?? .distantPast) >= s && ($0.day ?? .distantFuture) <= stop }
            cache!.historyUntil = dayFmt.string(from: stop)
            start = cal.date(byAdding: .day, value: 1, to: stop)
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(cache!) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL)
        }
        if Date().timeIntervalSince(lastRecent) > 900, let r = get(["days": "\(recentDays)"], cfg) {
            recent = r
            lastRecent = Date()
            status = ""
        }
        let history = cache!.history.filter { ($0.day ?? .distantFuture) <= historyEnd }
        return (history + recent.filter { ($0.day ?? .distantPast) > historyEnd }, cfg.host)
    }
}

// MARK: - Live Codex limit

/// Reads the live Codex plan usage the way the Codex app does: `GET {base}/wham/usage` with the ChatGPT login
/// Codex stores in ~/.codex/auth.json. The token is read per request, sent only to OpenAI, never stored or logged.
/// Automatic requests are throttled to every two minutes. A manual refresh asks immediately.
final class CodexLive {
    private(set) var status = ""
    private var last: Quota?
    private var accountID: String?
    private var lastAttempt = Date.distantPast
    private let minInterval: TimeInterval = 120

    private var home: String { ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex" }

    private func endpoint() -> URL {
        var base = "https://chatgpt.com/backend-api"
        if let cfg = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8),
           let m = cfg.range(of: #"(?m)^\s*chatgpt_base_url\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let line = String(cfg[m])
            if let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                base = String(line[line.index(after: q1)..<q2]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if (base.contains("chatgpt.com") || base.contains("chat.openai.com")) && !base.contains("/backend-api") { base += "/backend-api" }
            }
        }
        return URL(string: base + (base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"))!
    }

    func quota(forceRefresh: Bool = false) -> Quota? {
        if !forceRefresh && Date().timeIntervalSince(lastAttempt) < minInterval { return last }
        lastAttempt = Date()
        guard let data = FileManager.default.contents(atPath: home + "/auth.json"),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            status = "Sign in to Codex with ChatGPT to read limits"
            last = nil
            return nil
        }
        let account = tokens["account_id"] as? String
        if accountID != account { last = nil; accountID = account }
        var req = URLRequest(url: endpoint(), timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Tokenly", forHTTPHeaderField: "User-Agent")
        if let account, !account.isEmpty { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let done = DispatchSemaphore(value: 0)
        var body: Data?, code = 0
        var networkError: URLError.Code?
        URLSession.shared.dataTask(with: req) { d, resp, error in
            body = d
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            networkError = (error as? URLError)?.code
            done.signal()
        }.resume()
        done.wait()
        guard code == 200, let body = body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            if code == 401 || code == 403 {
                status = "Open Codex to sign in again"
                last = nil
            } else if networkError == .cannotFindHost || networkError == .dnsLookupFailed {
                status = "Codex server name lookup failed (DNS)"
            } else if networkError == .timedOut {
                status = "Codex limit check timed out"
            } else {
                switch code {
                case 0: status = "Couldn't reach Codex"
                case 200: status = "Couldn't read Codex limits"
                default: status = "Codex limit check failed (HTTP \(code))"
                }
            }
            return last
        }
        let now = Date()
        let rl = obj["rate_limit"] as? [String: Any] ?? [:]
        let meters = ["primary_window", "secondary_window"].compactMap { slot -> QuotaMeter? in
            guard let w = rl[slot] as? [String: Any], let used = w["used_percent"] as? NSNumber,
                  let secs = w["limit_window_seconds"] as? NSNumber else { return nil }
            var reset: Date?
            if let at = w["reset_at"] as? NSNumber, at.doubleValue > 0 { reset = Date(timeIntervalSince1970: at.doubleValue) }
            else if let after = w["reset_after_seconds"] as? NSNumber { reset = now.addingTimeInterval(after.doubleValue) }
            return QuotaMeter(label: Scanner.windowLabel(minutes: secs.doubleValue / 60), percent: used.doubleValue,
                              resetsAt: reset, window: secs.doubleValue)
        }.sorted { $0.window ?? 0 < $1.window ?? 0 }
        let credits = ((obj["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? NSNumber)?.intValue
        guard !meters.isEmpty else { status = "Codex returned no limits"; return last }
        status = ""
        last = Quota(product: "Codex", plan: (obj["plan_type"] as? String)?.capitalized, meters: meters,
                     asOf: now, source: "live", resetCredits: credits)
        return last
    }
}

// MARK: - Live Claude limit

/// Asks Claude Code itself for the live plan usage, the way the Agent SDK does: start the `claude` binary in a
/// safe, tool-less, session-less mode and exchange `initialize` + `get_usage` over its stdio control protocol.
/// No prompt is sent and no tokens are used; Claude Code reads its own login. At most once every 5 minutes.
final class ClaudeLive {
    private(set) var status = ""
    private var last: Quota?
    private var lastAttempt = Date.distantPast
    private let minInterval: TimeInterval = 300

    private func binary() -> String? {
        let env = ProcessInfo.processInfo.environment, home = NSHomeDirectory()
        var candidates = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func quota() -> Quota? {
        if Date().timeIntervalSince(lastAttempt) < minInterval { return last }
        lastAttempt = Date()
        guard let bin = binary() else { status = "Claude Code not found for the live read"; return last }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--print", "--safe-mode", "--no-session-persistence", "--strict-mcp-config",
                       "--mcp-config", #"{"mcpServers":{}}"#, "--tools", "", "--output-format", "stream-json",
                       "--input-format", "stream-json", "--verbose",
                       "--settings", #"{"env":{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":""}}"#]
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                  "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID"] { env.removeValue(forKey: k) }
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { status = "Couldn't start Claude Code"; return last }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } } // ends a hung read via EOF
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        defer { deadline.cancel(); if p.isRunning { p.terminate() } }
        func send(_ id: String, _ request: [String: Any]) {
            let msg: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
            if let d = try? JSONSerialization.data(withJSONObject: msg) { input.fileHandleForWriting.write(d + Data("\n".utf8)) }
        }
        send("tokenly-init", ["subtype": "initialize"])
        var buffer = Data(), payload: [String: Any]?, answered = false
        let out = output.fileHandleForReading
        reading: while true {
            let chunk = out.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["type"] as? String == "control_response", let r = o["response"] as? [String: Any] else { continue }
                if r["request_id"] as? String == "tokenly-init" {
                    send("tokenly-usage", ["subtype": "get_usage", "skip_behaviors": true])
                } else if r["request_id"] as? String == "tokenly-usage" {
                    answered = true
                    if r["subtype"] as? String == "success" { payload = r["response"] as? [String: Any] }
                    break reading
                }
            }
        }
        try? input.fileHandleForWriting.close()
        guard let pl = payload else { status = answered ? "Claude Code couldn't read usage" : "Claude Code didn't answer in time"; return last }
        if pl["rate_limits_available"] as? Bool == false { status = ""; last = nil; return nil } // API-key login: no plan limits
        let limits = pl["rate_limits"] as? [String: Any] ?? [:]
        let now = Date()
        let meters = claudeMeters(limits, now: now)
        guard !meters.isEmpty else { status = "Claude Code returned no limits"; return last }
        status = ""
        last = Quota(product: "Claude", plan: (pl["subscription_type"] as? String)?.capitalized, meters: meters, asOf: now, source: "live")
        return last
    }
}

// MARK: - Formatting

private let groupedInt: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f
}()
func usd(_ v: Double) -> String { v >= 1000 ? "$" + (groupedInt.string(from: NSNumber(value: v)) ?? "\(Int(v))") : String(format: "$%.2f", v) }
func historyCost(_ value: Double?, partial: Bool) -> String {
    guard let value else { return "—" }
    if partial { return value > 0 ? "≥ \(usd(value))" : "—" }
    return usd(value)
}
func tok(_ v: Double) -> String {
    v >= 1e9 ? String(format: "%.1fB", v / 1e9) : v >= 1e6 ? String(format: "%.1fM", v / 1e6)
        : v >= 1e3 ? String(format: "%.0fK", v / 1e3) : String(format: "%.0f", v)
}
func dayLabel(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
func hourLabel(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
func duration(_ s: Double) -> String {
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}
private let relFmt: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()
func relative(_ d: Date) -> String { relFmt.localizedString(for: d, relativeTo: Date()) }

// MARK: - Preferences

/// Settings shared by the menu, the Settings window and the menu bar title.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let ud = UserDefaults.standard
    var onChange: (() -> Void)?

    /// cost | tokens | both | quota
    @Published var menuBarFormat: String { didSet { ud.set(menuBarFormat, forKey: "menuBarFormat"); onChange?() } }
    /// Show the fullest plan limit in the menu bar from this % (0 = off).
    @Published var alertThreshold: Int { didSet { ud.set(alertThreshold, forKey: "alertThreshold"); onChange?() } }
    @Published var showDesktopWidget: Bool { didSet { ud.set(showDesktopWidget, forKey: "showDesktopWidget"); onChange?() } }
    /// Read-only import of the user's other devices from their Vibe Usage account.
    /// Read the Codex plan limit live from OpenAI with the Codex login on this Mac.
    @Published var liveCodex: Bool { didSet { ud.set(liveCodex, forKey: "liveCodex"); onDataChange?() } }
    /// Monthly plan prices in USD; 0 = guess from the plan badge.
    @Published var claudePlanPrice: Double { didSet { ud.set(claudePlanPrice, forKey: "claudePlanPrice") } }
    @Published var codexPlanPrice: Double { didSet { ud.set(codexPlanPrice, forKey: "codexPlanPrice") } }
    func planPrice(_ product: String, _ plan: String?) -> Double? {
        let set = product == "Claude" ? claudePlanPrice : product == "Codex" ? codexPlanPrice : 0
        if set > 0 { return set }
        switch (product, plan?.lowercased() ?? "") {
        case ("Claude", "max"), ("Codex", "pro"): return 200
        case ("Claude", "pro"), ("Codex", "plus"): return 20
        case ("Codex", "business"), ("Codex", "team"): return 30
        default: return nil
        }
    }
    /// Ask Claude Code for the live Claude plan limit (no prompt, no tokens).
    @Published var liveClaude: Bool { didSet { ud.set(liveClaude, forKey: "liveClaude"); onDataChange?() } }
    @Published var includeOtherDevices: Bool { didSet { ud.set(includeOtherDevices, forKey: "includeOtherDevices"); onDataChange?() } }
    var onDataChange: (() -> Void)?
    static let textScales: [CGFloat] = [1.0, 1.15, 1.3]
    /// One step smaller (-1) or larger (+1).
    func stepText(_ d: Int) {
        let i = Prefs.textScales.firstIndex(of: textScale) ?? 1
        textScale = Prefs.textScales[max(0, min(Prefs.textScales.count - 1, i + d))]
    }
    // Overview sections (Settings → Overview). Defaults keep the page short.
    @Published var showInsight: Bool { didSet { ud.set(showInsight, forKey: "showInsight") } }
    @Published var showDetails: Bool { didSet { ud.set(showDetails, forKey: "showDetails") } }
    @Published var showTrend: Bool { didSet { ud.set(showTrend, forKey: "showTrend") } }
    @Published var showLimits: Bool { didSet { ud.set(showLimits, forKey: "showLimits") } }
    @Published var showLimitDetails: Bool { didSet { ud.set(showLimitDetails, forKey: "showLimitDetails") } }
    @Published var showPeriodStats: Bool { didSet { ud.set(showPeriodStats, forKey: "showPeriodStats") } }
    @Published var splitByProvider: Bool { didSet { ud.set(splitByProvider, forKey: "splitByProvider") } }
    /// Panel unfolded: Overview plus Breakdown and History on one scrolling page.
    @Published var expanded: Bool { didSet { ud.set(expanded, forKey: "expanded") } }
    /// Color the menu bar text orange/red at the plan-limit alert (off: plain text).
    @Published var colorMenuBar: Bool { didSet { ud.set(colorMenuBar, forKey: "colorMenuBar"); onChange?() } }
    /// Solid dark panel background (default), so text stays readable over light windows; off = see-through glass.
    @Published var solidBackground: Bool { didSet { ud.set(solidBackground, forKey: "solidBackground"); onChange?() } }
    /// Panel text size: 1.0 default, 1.15 large, 1.3 larger.
    @Published var textScale: CGFloat { didSet { ud.set(Double(textScale), forKey: "textScale"); onChange?() } }
    @Published var launchAtLogin: Bool {
        didSet {
            let svc = SMAppService.mainApp
            guard launchAtLogin != (svc.status == .enabled) else { return }
            do {
                if launchAtLogin { try svc.register() } else { try svc.unregister() }
            } catch {
                let a = NSAlert()
                a.messageText = "Could not change login item"
                a.informativeText = "\(error.localizedDescription)\nMove Tokenly.app to /Applications and try again."
                a.runModal()
                DispatchQueue.main.async { self.launchAtLogin = svc.status == .enabled }
            }
        }
    }

    init() {
        menuBarFormat = ud.string(forKey: "menuBarFormat") ?? "cost"
        alertThreshold = ud.object(forKey: "alertThreshold") as? Int ?? 80
        showDesktopWidget = ud.bool(forKey: "showDesktopWidget")
        includeOtherDevices = ud.bool(forKey: "includeOtherDevices")
        liveCodex = ud.object(forKey: "liveCodex") as? Bool ?? true
        liveClaude = ud.object(forKey: "liveClaude") as? Bool ?? true
        claudePlanPrice = ud.double(forKey: "claudePlanPrice")
        codexPlanPrice = ud.double(forKey: "codexPlanPrice")
        textScale = CGFloat(ud.object(forKey: "textScale") as? Double ?? 1.15)
        solidBackground = ud.object(forKey: "solidBackground") as? Bool ?? true
        showInsight = ud.object(forKey: "showInsight") as? Bool ?? true
        showDetails = ud.object(forKey: "showDetails") as? Bool ?? false
        showTrend = ud.object(forKey: "showTrend") as? Bool ?? true
        showLimits = ud.object(forKey: "showLimits") as? Bool ?? true
        showLimitDetails = ud.object(forKey: "showLimitDetails") as? Bool ?? false
        showPeriodStats = ud.object(forKey: "showPeriodStats") as? Bool ?? false
        splitByProvider = ud.object(forKey: "splitByProvider") as? Bool ?? true
        colorMenuBar = ud.object(forKey: "colorMenuBar") as? Bool ?? false
        expanded = ud.bool(forKey: "expanded")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

let menuBarFormats = [("Today's cost", "cost"), ("Today's tokens", "tokens"), ("Cost + tokens", "both"),
                      ("Cost over tokens (two lines)", "stacked"), ("Fullest plan limit", "quota")]
let alertThresholds = [("Off", 0), ("70%", 70), ("80%", 80), ("90%", 90)]

// MARK: - Store

enum Preset: String, CaseIterable, Identifiable {
    case today = "Today", h24 = "24H", week = "7D", month = "30D", quarter = "90D", all = "All", custom = "Custom"
    case codexReset = "Since Codex reset"
    var id: String { rawValue }
    var days: Int { [1, 1, 7, 30, 90, 0, 0, 0][Preset.allCases.firstIndex(of: self)!] }
    var title: String { ["Today", "Last 24 hours", "Last 7 days", "Last 30 days", "Last 90 days", "All time", "Custom range…", "Since Codex reset"][Preset.allCases.firstIndex(of: self)!] }
}

/// A time range [from, to), charted by `unit` (.hour, .day or .month).
struct Span {
    let from: Date, to: Date, days: Int, title: String, unit: Calendar.Component
    var codexWindow = false
    var hourly: Bool { unit == .hour }
    var firstBucket: Date { codexWindow ? cal.dateInterval(of: unit, for: from)!.start : from }
    var hourCount: Int { codexWindow ? max(1, Int(ceil(to.timeIntervalSince(firstBucket) / 3600))) : 24 }
    var previous: (from: Date, to: Date) { (from.addingTimeInterval(-to.timeIntervalSince(from)), from) }
}

final class Store: ObservableObject {
    private static let codexResetPreference = "showUsageSinceCodexReset"
    @Published var report: Report?
    @Published var preset = UserDefaults.standard.bool(forKey: Store.codexResetPreference) ? Preset.codexReset : .today {
        didSet { hover = nil }
    }
    @Published var pickedDay: Date? { didSet { hover = nil } }
    @Published var provider: String? // nil = all providers
    @Published var model: String? // nil = all models
    @Published var project: String? // nil = all projects
    @Published var device: String? // nil = all devices
    @Published var page = "overview" // overview | breakdown | history
    @Published var planProduct = "Codex" // Plan weeks card
    @Published var metric = "cost" // charts: cost | tokens | time
    @Published var customFrom = daysAgo(13) // Custom range, inclusive local days
    @Published var customTo = today()
    @Published var mode = "provider" // breakdown: provider | model | project | day
    @Published var hover: Int? // hovered bar in the trend strip
    @Published var contentHeight: CGFloat = 0 // measured panel content, for the popover's scroll cap
    var onUpdate: ((Report) -> Void)?
    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "tokenly.scan", qos: .utility) // serializes scanner access

    func selectPreset(_ selection: Preset) {
        preset = selection
        pickedDay = nil
        UserDefaults.standard.set(selection == .codexReset, forKey: Self.codexResetPreference)
        if selection == .codexReset && Prefs.shared.includeOtherDevices && report?.codexResetRemote == nil { refresh() }
    }

    @Published var refreshing = false
    func refresh(forceCodexRefresh: Bool = false) {
        refreshing = true
        let includeCodexReset = preset == .codexReset
        let initial = report == nil
        queue.async {
            self.scanner.liveCodex = Prefs.shared.liveCodex
            self.scanner.liveClaude = Prefs.shared.liveClaude
            let publishBeforeBackfill: ((Report) -> Void)? = initial ? { partial in
                DispatchQueue.main.async {
                    if self.report == nil { self.report = partial }
                }
            } : nil
            let r = ProcessInfo.processInfo.environment["TOKENLY_DEMO"] != nil ? Report.demo()
                : self.scanner.run(otherDevices: Prefs.shared.includeOtherDevices, forceCodexRefresh: forceCodexRefresh,
                                   includeCodexReset: includeCodexReset, publishBeforeBackfill: publishBeforeBackfill)
            DispatchQueue.main.async { self.report = r; self.refreshing = false; self.onUpdate?(r) }
        }
    }

    var span: Span {
        if let d = pickedDay {
            return Span(from: d, to: cal.date(byAdding: .day, value: 1, to: d)!, days: 1,
                        title: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), unit: .hour)
        }
        switch preset {
        case .today: return Span(from: today(), to: tomorrow(), days: 1, title: preset.title, unit: .hour)
        case .h24:
            let next = cal.dateInterval(of: .hour, for: Date())!.end
            return Span(from: next.addingTimeInterval(-86400), to: next, days: 1, title: preset.title, unit: .hour)
        case .codexReset:
            let now = Date(), start = report?.codexResetStart ?? now
            let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: now)).day ?? 0) + 1
            return Span(from: start, to: now, days: days, title: preset.title,
                        unit: now.timeIntervalSince(start) <= 86400 ? .hour : .day, codexWindow: true)
        case .custom:
            let from = cal.startOfDay(for: min(customFrom, customTo)), last = cal.startOfDay(for: max(customFrom, customTo))
            let to = cal.date(byAdding: .day, value: 1, to: last)!
            let days = max(1, cal.dateComponents([.day], from: from, to: to).day ?? 1)
            let title = days == 1 ? dayLabel(from) : "\(dayLabel(from)) – \(dayLabel(last))"
            return Span(from: from, to: to, days: days, title: title, unit: days == 1 ? .hour : days > 120 ? .month : .day)
        case .all:
            let first = cal.dateInterval(of: .month, for: report?.firstDay ?? today())!.start
            let days = (cal.dateComponents([.day], from: first, to: tomorrow()).day ?? 1)
            return Span(from: first, to: tomorrow(), days: max(days, 1), title: "All time", unit: .month)
        default: return Span(from: daysAgo(preset.days - 1), to: tomorrow(), days: preset.days, title: preset.title, unit: .day)
        }
    }
}

// MARK: - Widget UI

let accent = Color(red: 0.67, green: 0.58, blue: 1.0)
let panelBackground = Color(red: 0.09, green: 0.09, blue: 0.11)

/// Text size from Settings; the panel widens with it so rows don't truncate.
func fs(_ size: CGFloat) -> CGFloat { (size * Prefs.shared.textScale).rounded() }
var panelWidth: CGFloat { (360 * Prefs.shared.textScale).rounded() }
let heatWeeks = 13

/// Small uppercase, letter-spaced section label.
func cap(_ s: String) -> some View {
    Text(s.uppercased()).font(.system(size: fs(9.5), weight: .semibold)).tracking(1.1).foregroundColor(.secondary)
        .lineLimit(1)
}

func bar(_ share: Double, _ color: Color = accent, height: CGFloat = 3) -> some View {
    GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(color).frame(width: max(0, geo.size.width * min(share, 1)))
        }
    }
    .frame(height: height)
}

/// Text tab with an underline when selected.
func tab(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 3) {
            Text(label.uppercased()).font(.system(size: fs(10), weight: .semibold)).tracking(0.6)
                .foregroundColor(on ? accent : .secondary)
            Rectangle().fill(on ? accent : Color.clear).frame(height: 1.5)
        }
        .fixedSize().contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
}
extension View { func card() -> some View { modifier(Card()) } }

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct WidgetView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs = Prefs.shared // re-render when the text size changes
    let menu: NSMenu
    var inPopover = false

    var pickedDay: Date? { store.pickedDay }
    var provider: String? { store.provider }
    var scopeName: String { store.model ?? store.project ?? provider ?? "All providers" }

    func matchesFilters(_ entry: Entry) -> Bool {
        (provider == nil || entry.provider == provider) && (store.model == nil || entry.model == store.model)
            && (store.project == nil || entry.project == store.project) && (store.device == nil || entry.device == store.device)
    }

    /// Entries in [from, to) for the selected provider / model / project (all when nil).
    func scoped(_ r: Report, _ from: Date, _ to: Date) -> [Entry] {
        r.entries(from: from, to: to).filter(matchesFilters)
    }

    func periodEntries(_ r: Report, _ span: Span) -> [Entry] {
        span.codexWindow ? r.codexUsageSinceReset(to: span.to).filter(matchesFilters) : scoped(r, span.from, span.to)
    }
    func sum(_ es: [Entry]) -> Row { es.reduce(into: Row()) { $0.add($1.row) } }
    /// Providers that have any usage in the scan window, in fixed order.
    var present: [(name: String, color: Color)] {
        let seen = Set(store.report?.entries.map { $0.provider } ?? [])
        return providers.filter { seen.contains($0.name) }
    }

    /// In the popover, scroll once the content is taller than the screen allows.
    @ViewBuilder var body: some View {
        if inPopover {
            let maxH = CommandLine.arguments.contains("--tall") ? 5000 : (NSScreen.main?.visibleFrame.height ?? 800) - 40
            ScrollView(.vertical, showsIndicators: false) {
                content.background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .frame(width: panelWidth, height: min(max(store.contentHeight, 120), maxH))
            .background(prefs.solidBackground ? panelBackground.ignoresSafeArea() : nil)
            .onPreferenceChange(HeightKey.self) { store.contentHeight = $0 }
        } else {
            content
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let r = store.report, CommandLine.arguments.contains("only=history") {
                planHistory(r)
                activity(r)
            } else if let r = store.report {
                controls(r)
                hero(r)
                if prefs.showLimits && (!r.quotas.isEmpty || !r.quotaReadErrors.isEmpty) { quotas(r) }
                if prefs.showPeriodStats { totals(r) }
                if prefs.expanded {
                    section("Breakdown")
                    filters(r)
                    tokenMix(r)
                    breakdown(r)
                    section("History")
                    activity(r)
                    planHistory(r)
                    monthly(r)
                }
                foldButton
                if !r.unpriced.isEmpty {
                    Label("No price for \(r.unpriced.sorted().joined(separator: ", ")) — add it in Settings › Pricing",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: fs(10))).foregroundColor(.orange)
                }
            } else {
                Text("Scanning logs…").font(.system(size: fs(11))).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            footer
        }
        .padding(16)
        .frame(width: panelWidth)
    }

    // MARK: header & filters

    var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(nsImage: logoImage(points: fs(20), template: false)).interpolation(.none)
                Text("TOKENLY").font(.system(size: fs(11), weight: .semibold).width(.expanded)).tracking(0.8)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .overlay(inPopover ? nil : DragHandle(menu: menu)) // desktop: drag to move, right-click for menu
            Spacer(minLength: 4)
            Button { prefs.expanded.toggle() } label: {
                Image(systemName: prefs.expanded ? "chevron.up.circle" : "chevron.down.circle").font(.system(size: fs(14)))
            }
            .buttonStyle(.borderless).foregroundColor(.secondary)
            .help(prefs.expanded ? "Fold to the overview" : "Show breakdown and history")
        }
    }

    /// Divider label between the overview and the unfolded sections.
    func section(_ title: String) -> some View {
        HStack(spacing: 8) {
            cap(title)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .padding(.top, 4)
    }

    var foldButton: some View {
        Button { prefs.expanded.toggle() } label: {
            HStack(spacing: 4) {
                Text(prefs.expanded ? "Show less" : "Show all")
                Image(systemName: prefs.expanded ? "chevron.up" : "chevron.down")
            }
            .font(.system(size: fs(11), weight: .medium)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Period pills (like Vibe Usage's date row), custom dates, and the device picker; shared by every page.
    func controls(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(Preset.allCases.filter { $0 != .codexReset }) { p in
                    pill(p.rawValue, pickedDay == nil && store.preset == p) { store.selectPreset(p) }
                }
                Spacer(minLength: 0)
            }
            if pickedDay == nil && store.preset == .custom {
                HStack(spacing: 6) {
                    cap("From")
                    DatePicker("", selection: Binding(get: { store.customFrom }, set: { store.customFrom = $0; store.hover = nil }),
                               in: ...today(), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().controlSize(.small).fixedSize()
                    cap("To")
                    DatePicker("", selection: Binding(get: { store.customTo }, set: { store.customTo = $0; store.hover = nil }),
                               in: store.customFrom...today(), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().controlSize(.small).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            let showCodexReset = r.codexResetStart != nil || store.preset == .codexReset
            if showCodexReset || pickedDay != nil || r.devices.count > 1 {
                HStack(spacing: 6) {
                    if let d = pickedDay {
                        pill("\(dayLabel(d))  ✕", true) { store.pickedDay = nil }.help("Back to \(store.preset.title)")
                    } else if showCodexReset {
                        pill(Preset.codexReset.rawValue, store.preset == .codexReset) { store.selectPreset(.codexReset) }
                            .help("Show usage since your last Codex weekly reset")
                    }
                    Spacer(minLength: 0)
                    if r.devices.count > 1 {
                        Picker("", selection: Binding(get: { store.device }, set: { store.device = $0 })) {
                            Text("All \(r.devices.count) devices").tag(String?.none)
                            Divider()
                            ForEach(r.devices, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    }
                }
            }
        }
    }

    /// Rounded selectable pill, shared by the period row.
    func pill(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).fixedSize()
                .font(.system(size: fs(11), weight: on ? .semibold : .medium))
                .padding(.horizontal, fs(8)).padding(.vertical, fs(3.5))
                .background(Capsule().fill(on ? accent.opacity(0.22) : Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(on ? accent.opacity(0.8) : Color.clear, lineWidth: 1))
                .foregroundColor(on ? .primary : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Shown once other devices are imported: all devices, this Mac, or one device picked in the breakdown.
    func devicesRow(_ r: Report) -> some View {
        HStack(spacing: 10) {
            cap("Devices")
            tab("All \(r.devices.count)", store.device == nil) { store.device = nil }
            tab(thisMac, store.device == thisMac) { store.device = thisMac }
            if let d = store.device, d != thisMac {
                tab("\(d) ✕", true) { store.device = nil }.help("Click to show all devices")
            }
            Spacer()
        }
    }

    func filters(_ r: Report) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", nil, .primary)
                    ForEach(present, id: \.name) { chip($0.name, $0.name, $0.color) }
                }
            }
            if let p = store.project {
                Button { store.project = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(p).lineLimit(1).truncationMode(.middle).frame(maxWidth: 70)
                        Image(systemName: "xmark").font(.system(size: fs(8), weight: .bold))
                    }
                    .font(.system(size: fs(11), weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(accent.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain).help("Project: \(p) — click to clear")
            }
            Spacer(minLength: 4)
            modelPicker(r)
        }
    }

    func chip(_ label: String, _ value: String?, _ color: Color) -> some View {
        let on = provider == value
        return Button { store.provider = value; store.model = nil } label: {
            HStack(spacing: 5) {
                if value != nil { Circle().fill(color).frame(width: 6, height: 6) }
                Text(label).fixedSize()
            }
            .font(.system(size: fs(11), weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? accent.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? accent.opacity(0.7) : Color.clear, lineWidth: 1))
            .foregroundColor(on ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Dropdown of models grouped by provider; picking one filters the whole panel.
    func modelPicker(_ r: Report) -> some View {
        let cost = Dictionary(grouping: r.entries, by: { $0.model }).mapValues { $0.reduce(0) { $0 + $1.row.cost } }
        let groups = present.filter { provider == nil || $0.name == provider }.map { p in
            (p.name, cost.keys.filter { providerOf($0) == p.name }.sorted { cost[$0]! > cost[$1]! })
        }
        return Picker("", selection: Binding(get: { store.model }, set: { store.model = $0 })) {
            Text("All models").tag(String?.none)
            ForEach(groups, id: \.0) { g in
                Section(g.0) { ForEach(g.1, id: \.self) { Text($0).tag(String?.some($0)) } }
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).frame(maxWidth: 120)
    }

    // MARK: plan limits

    /// "$200/mo plan · last 30 days worth $8,720 (44×)": what you pay vs what your use was worth at API prices.
    @ViewBuilder func planValue(_ r: Report, _ q: Quota) -> some View {
        if let price = prefs.planPrice(q.product, q.plan), price > 0 {
            let worth = productCost(r.entries, q.product, from: daysAgo(29))
            HStack(spacing: 4) {
                Text("\(String(format: "$%.0f", price))/mo plan · last 30 days worth \(usd(worth))")
                Spacer(minLength: 4)
                Text(String(format: "%.1f×", worth / price)).fontWeight(.semibold).foregroundColor(worth >= price ? .green : .orange)
            }
            .font(.system(size: fs(10))).foregroundColor(.secondary).monospacedDigit().lineLimit(1)
            .help("Your \(q.product) usage over the last 30 days (all devices) priced at API list prices, compared with what the plan costs. Set your price in Settings → Plan prices.")
        }
    }

    func quotaColor(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 70 ? .orange : accent }

    /// Latest subscription usage and available banked resets.
    func quotas(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cap("Plan limits")
            ForEach(r.quotas) { q in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(q.product).font(.system(size: fs(12), weight: .medium))
                        if let plan = q.plan {
                            Text(plan.uppercased()).font(.system(size: fs(8.5), weight: .semibold)).tracking(0.6)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.09))).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let c = q.resetCredits {
                            Text("↻ \(c) reset\(c == 1 ? "" : "s") left").font(.system(size: fs(9.5))).foregroundColor(.secondary)
                                .help("Banked resets available in Codex")
                        }
                        let readingLabel = q.source == "live" && r.quotaReadErrors[q.product] == nil ? "Read" : "Saved"
                        Text(q.asOf.map { "\(readingLabel) \(relative($0))" } ?? "Saved reading")
                            .font(.system(size: fs(9.5))).foregroundColor(.secondary)
                            .help(q.asOf.map { "\(q.source), \($0.formatted(date: .abbreviated, time: .shortened))" } ?? q.source)
                    }
                    if let issue = r.quotaReadErrors[q.product] { quotaReadIssue(issue) }
                    planValue(r, q)
                    ForEach(q.meters) { m in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Text(m.label).foregroundColor(.secondary)
                                Spacer()
                                if let reset = m.resetsAt {
                                    Text(prefs.showLimitDetails ? "resets \(relative(reset))" : relative(reset)).foregroundColor(.secondary)
                                }
                                Text("\(m.recorded != nil ? "≈" : "")\(Int(m.percent.rounded()))%").fontWeight(.semibold)
                                    .foregroundColor(m.percent >= 70 ? quotaColor(m.percent) : .primary)
                                    .frame(minWidth: fs(34), alignment: .trailing)
                            }
                            .font(.system(size: fs(10.5))).monospacedDigit()
                            bar(m.percent / 100, quotaColor(m.percent), height: 4)
                            if let perFull = m.perFull {
                                HStack {
                                    if let rec = m.recorded, let at = q.asOf {
                                        Text("\(Int(rec.rounded()))% \(relative(at)) + usage since")
                                            .help("Last reading: \(Int(rec.rounded()))% \(relative(at)) (\(q.source)). The rest is estimated from usage on all devices since then, so it can be off by a few points.")
                                    } else {
                                        Text("\(usd(m.spent ?? perFull * m.percent / 100)) used").lineLimit(1)
                                    }
                                    Spacer()
                                    Text("100% ≈ \(usd(perFull))").fontWeight(.semibold).foregroundColor(.primary)
                                        .help(limitWorthHelp(m, q))
                                }
                                .font(.system(size: fs(9.5))).foregroundColor(.secondary).monospacedDigit()
                            }
                            if !prefs.showLimitDetails, let proj = m.projected, proj > 100, m.percent < 100 {
                                Text("may run out before reset").font(.system(size: fs(9.5))).foregroundColor(.secondary)
                            }
                            if prefs.showLimitDetails, let e = m.elapsed, let proj = m.projected {
                                bar(e, Color.primary.opacity(0.35), height: 2)
                                HStack {
                                    Text("\(Int((e * 100).rounded()))% of window passed")
                                    Spacer()
                                    if m.percent >= 100 {
                                        Text("limit reached").foregroundColor(.red)
                                    } else if proj > 100 {
                                        Text("on pace for \(Int(proj.rounded()))% — may run out").foregroundColor(proj >= 120 ? .red : .orange)
                                    } else {
                                        Text("on pace for \(Int(proj.rounded()))%")
                                    }
                                }
                                .font(.system(size: fs(9.5))).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            ForEach(r.quotaReadErrors.keys.sorted().filter { product in !r.quotas.contains { $0.product == product } }, id: \.self) { product in
                VStack(alignment: .leading, spacing: 6) {
                    Text(product).font(.system(size: fs(12), weight: .medium))
                    if let issue = r.quotaReadErrors[product] { quotaReadIssue(issue) }
                }
            }
        }
        .card()
    }

    private func quotaReadIssue(_ issue: String) -> some View {
        Label(issue, systemImage: "exclamationmark.triangle")
            .font(.system(size: fs(10))).foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: hero

    func hero(_ r: Report) -> some View {
        let g = store.span
        let es = periodEntries(r, g)
        let cur = sum(es)
        let compare = !g.codexWindow && (store.preset != .all || pickedDay != nil)
        let prev = compare ? sum(scoped(r, g.previous.from, g.previous.to)) : Row()
        let remote = es.contains { $0.device != thisMac }
        return VStack(alignment: .leading, spacing: 8) {
            if g.codexWindow && r.codexResetStart == nil {
                Text("Codex reset time unavailable").font(.system(size: fs(11))).foregroundColor(.secondary)
            } else {
                if g.codexWindow { cap("Since \(g.from.formatted(.dateTime.month(.abbreviated).day().hour().minute()))") }
                if scopeName != "All providers" { cap(scopeName) }
                HStack(alignment: .top, spacing: fs(22)) {
                    headline(usd(cur.cost), "Cost", cur.cost, prev.cost, g.days)
                    headline(tok(cur.tokens), "Tokens", cur.tokens, prev.tokens, g.days)
                    Spacer(minLength: 0)
                }
                if prefs.showInsight {
                    Text(insight(es, cur, g.days)).font(.system(size: fs(12))).foregroundColor(.primary.opacity(0.85))
                }
                if prefs.showDetails {
                    Text(cur.calls == 0 ? "\(tok(cur.tokens)) tokens"
                         : "\(tok(cur.tokens)) tokens · \(Int(cur.calls)) calls · \(duration(activeSeconds(es))) active\(remote ? " on this Mac" : "")")
                        .font(.system(size: fs(10.5))).foregroundColor(.secondary).monospacedDigit()
                        .help("Active time: 5-minute slots with at least one model call")
                }
                if prefs.showTrend { trend(r, g) }
                if g.codexWindow && prefs.includeOtherDevices && r.codexResetRemote == nil && store.device != thisMac {
                    Text(store.refreshing ? "Loading usage from other devices…" : "Usage from other devices unavailable")
                        .font(.system(size: fs(9.5))).foregroundColor(.secondary)
                } else if !g.codexWindow && prefs.showTrend && prefs.showDetails && remote && g.hourly {
                    Text("Other devices report daily totals; they appear in the first hour.")
                        .font(.system(size: fs(9.5))).foregroundColor(.secondary)
                }
            }
        }
        .card()
    }

    /// Breakdown page: what the tokens are made of, and what the cache saved.
    func tokenMix(_ r: Report) -> some View {
        let g = store.span
        let cur = sum(periodEntries(r, g))
        let inputSide = cur.input + cur.cacheRead + cur.cacheWrite
        return VStack(alignment: .leading, spacing: 8) {
            cap("Token mix · \(g.title) · \(tok(cur.tokens))")
            HStack(alignment: .top, spacing: 10) {
                mix("Input", cur.input, cur.tokens)
                mix("Output", cur.output, cur.tokens)
                mix("Cached", cur.cacheRead, cur.tokens)
                mix("Writes", cur.cacheWrite, cur.tokens)
            }
            cap("Cache hit \(inputSide > 0 ? String(format: "%.0f%%", cur.cacheRead / inputSide * 100) : "—") · saved \(usd(cur.saved)) · list prices")
        }
        .card()
    }

    /// Overview page: three numbers about the selected period.
    func totals(_ r: Report) -> some View {
        let g = store.span
        let es = periodEntries(r, g)
        let cur = sum(es)
        let hourly = g.hourly
        let buckets = Dictionary(grouping: es, by: { hourly ? $0.hour : $0.day }).mapValues { sum($0).cost }
        let busiest = buckets.max { $0.value < $1.value }
        return HStack(spacing: 0) {
            if hourly {
                stat("Active hours", "\(buckets.filter { $0.value > 0 }.count)/\(g.hourCount)")
                stat("Busiest hour", busiest.map { usd($0.value) } ?? "—", busiest.map { hourLabel($0.key) })
            } else {
                stat("Active days", "\(buckets.filter { $0.value > 0 }.count)/\(g.days)")
                stat("Busiest day", busiest.map { usd($0.value) } ?? "—", busiest.map { dayLabel($0.key) })
            }
            stat("Cache saved", usd(cur.saved))
        }
        .card()
    }

    func headline(_ value: String, _ label: String, _ cur: Double, _ prev: Double, _ days: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: fs(31), weight: .light).width(.expanded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                cap(label)
                if prev > 0 && cur > 0 {
                    let pct = (cur - prev) / prev * 100
                    Text(pct >= 200 ? String(format: "▲ %.0f×", cur / prev) : String(format: "%@ %.0f%%", pct >= 0 ? "▲" : "▼", abs(pct)))
                        .font(.system(size: fs(9.5), weight: .semibold)).monospacedDigit()
                        .foregroundColor(pct >= 0 ? .orange : .green)
                        .help("vs the previous \(days == 1 ? "day" : "\(days) days")")
                }
            }
        }
    }

    /// One sentence that says what the numbers mean.
    func insight(_ es: [Entry], _ cur: Row, _ days: Int) -> String {
        if cur.tokens == 0 { return "No usage in this period." }
        var s = days > 1 ? "\(usd(cur.cost / Double(days))) a day."
            : cur.calls > 0 ? "\(usd(cur.cost / cur.calls)) per call." : ""
        if store.model == nil {
            let groups = Dictionary(grouping: es, by: { provider == nil ? $0.provider : $0.model })
                .mapValues { $0.reduce(0) { $0 + $1.row.cost } }
            if groups.count == 1, let only = groups.first {
                s += " All of it on \(only.key)."
            } else if let top = groups.max(by: { $0.value < $1.value }), cur.cost > 0 {
                s += " \(top.key) took \(Int((top.value / cur.cost * 100).rounded()))% of it."
            }
        } else {
            let side = cur.input + cur.cacheRead + cur.cacheWrite
            if side > 0 { s += " Cache served \(Int((cur.cacheRead / side * 100).rounded()))% of input." }
        }
        return s
    }

    /// Bars by hour (Today, 24H, a picked day) or by day; hover for values, click a day to focus it.
    func trend(_ r: Report, _ g: Span) -> some View {
        let first = g.firstBucket
        let n = g.hourly ? g.hourCount : g.unit == .month ? (cal.dateComponents([.month], from: first, to: today()).month ?? 0) + 1 : g.days
        let start: (Int) -> Date = { i in
            g.hourly ? first.addingTimeInterval(Double(i) * 3600) : cal.date(byAdding: g.unit, value: i, to: first)!
        }
        var slots = Array(repeating: Row(), count: n)
        var active = Array(repeating: Set<Int>(), count: n)
        var byProvider = Array(repeating: [String: Row](), count: n)
        for e in periodEntries(r, g) {
            let i = g.hourly ? Int(e.hour.timeIntervalSince(first) / 3600)
                : cal.dateComponents([g.unit], from: first, to: e.day).value(for: g.unit) ?? -1
            if i >= 0 && i < n {
                slots[i].add(e.row); active[i].formUnion(e.slots)
                byProvider[i][e.provider, default: Row()].add(e.row)
            }
        }
        // Split bars by provider (cost or tokens), in the fixed provider order, when more than one is in view.
        let inView = providers.filter { p in byProvider.contains { $0[p.name] != nil } }
        let stacked = prefs.splitByProvider && store.metric != "time" && inView.count > 1
        let part: (Int, String) -> Double = { i, p in
            let row = byProvider[i][p] ?? Row()
            return store.metric == "tokens" ? row.tokens : row.cost
        }
        let value: (Int) -> Double = { i in
            store.metric == "tokens" ? slots[i].tokens : store.metric == "time" ? Double(active[i].count) * slotSeconds : slots[i].cost
        }
        let fmt: (Double) -> String = { v in store.metric == "tokens" ? tok(v) : store.metric == "time" ? duration(v) : usd(v) }
        let maxV = (0..<n).map(value).max() ?? 0
        let hi = store.hover.flatMap { $0 < n ? $0 : nil }
        let label: (Int) -> String = { i in
            g.hourly ? hourLabel(i == 0 ? g.from : start(i))
                : g.unit == .month ? start(i).formatted(.dateTime.month(.abbreviated).year(.twoDigits)) : dayLabel(start(i))
        }
        let peak = (0..<n).max { value($0) < value($1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let i = hi {
                    cap("\(label(i)) · \(usd(slots[i].cost)) · \(tok(slots[i].tokens))\(active[i].isEmpty ? "" : " · " + duration(Double(active[i].count) * slotSeconds))")
                } else {
                    if prefs.showDetails, let p = peak, maxV > 0 { cap("Peak \(fmt(maxV)) · \(label(p))") }
                }
                Spacer()
                tab("$", store.metric == "cost") { store.metric = "cost" }.help("Cost")
                tab("Tok", store.metric == "tokens") { store.metric = "tokens" }.help("Tokens")
                tab("Time", store.metric == "time") { store.metric = "time" }.help("Active time (this Mac)")
            }
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: n > 40 ? 1 : 2) {
                    ForEach(0..<n, id: \.self) { i in
                        let v = value(i)
                        Group {
                            if stacked && v > 0 && maxV > 0 {
                                VStack(spacing: 0) {
                                    ForEach(inView.reversed(), id: \.name) { p in
                                        let pv = part(i, p.name)
                                        if pv > 0 { Rectangle().fill(p.color).frame(height: geo.size.height * pv / maxV) }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                            } else {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(v > 0 ? accent : Color.primary.opacity(0.15))
                                    .frame(height: v > 0 && maxV > 0 ? max(2, geo.size.height * v / maxV) : 2)
                            }
                        }
                        .opacity(hi == nil || hi == i ? 1 : 0.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): store.hover = min(n - 1, max(0, Int(p.x / geo.size.width * CGFloat(n))))
                    case .ended: store.hover = nil
                    }
                }
                .onTapGesture { loc in
                    guard g.unit == .day else { return }
                    let i = min(n - 1, max(0, Int(loc.x / geo.size.width * CGFloat(n))))
                    store.pickedDay = start(i)
                }
            }
            .frame(height: 40)
            HStack {
                Text(label(0))
                Spacer()
                Text(label(n - 1))
            }
            .font(.system(size: fs(8.5))).foregroundColor(.secondary)
            if stacked {
                // Legend; while hovering it shows each provider's share of that bar.
                HStack(spacing: 10) {
                    ForEach(inView, id: \.name) { p in
                        HStack(spacing: 4) {
                            Circle().fill(p.color).frame(width: fs(6), height: fs(6))
                            Text(hi.map { fmt(part($0, p.name)) } ?? p.name)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: fs(9.5))).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    func mix(_ label: String, _ v: Double, _ total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            cap(label)
            Text(tok(v)).font(.system(size: fs(14), weight: .regular).width(.expanded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(total > 0 ? String(format: "%.1f%%", v / total * 100) : "—")
                .font(.system(size: fs(9.5))).foregroundColor(.secondary).monospacedDigit()
            bar(total > 0 ? v / total : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: activity

    func activity(_ r: Report) -> some View {
        let start = cal.date(byAdding: .day, value: -7 * (heatWeeks - 1),
                             to: cal.dateInterval(of: .weekOfYear, for: today())!.start)!
        let daily = Dictionary(grouping: scoped(r, start, tomorrow()), by: { $0.day }).mapValues { es -> Double in
            store.metric == "tokens" ? es.reduce(0) { $0 + $1.row.tokens }
                : store.metric == "time" ? activeSeconds(es) : es.reduce(0) { $0 + $1.row.cost }
        }
        let fmt: (Double) -> String = { v in store.metric == "tokens" ? tok(v) : store.metric == "time" ? duration(v) : usd(v) }
        let maxV = daily.values.max() ?? 0
        let peak = daily.max { $0.value < $1.value }
        let g = store.span
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                cap("Activity · \(heatWeeks) weeks")
                Spacer()
                if let p = peak, p.value > 0 { cap("Peak \(fmt(p.value)) · \(dayLabel(p.key))") }
            }
            HStack(spacing: 0) {
                ForEach(0..<heatWeeks, id: \.self) { w in
                    let first = cal.date(byAdding: .day, value: 7 * w, to: start)!
                    let monthStart = (0..<7).contains { cal.component(.day, from: cal.date(byAdding: .day, value: $0, to: first)!) == 1 }
                    VStack(spacing: 3) {
                        Text(w == 0 || monthStart ? first.addingTimeInterval(monthStart ? 6 * 86400 : 0)
                                .formatted(.dateTime.month(.abbreviated)).uppercased() : " ")
                            .font(.system(size: fs(8), weight: .semibold)).foregroundColor(.secondary)
                            .fixedSize().frame(height: 10)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: 7 * w + d, to: start)!
                            dot(day, daily[day] ?? 0, maxV, day >= (g.codexWindow ? cal.startOfDay(for: g.from) : g.from) && day < g.to)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            cap("Dot size = \(store.metric == "tokens" ? "tokens" : store.metric == "time" ? "active time" : "cost") that day · click to focus")
        }
        .card()
    }

    /// Plan usage by week: cost, full limits used (cost ÷ that week's 100% value) and detected resets.
    func planHistory(_ r: Report) -> some View {
        let history = Dictionary(uniqueKeysWithValues: ["Claude", "Codex"].map { ($0, planWeeks(r, $0)) })
        let products = ["Claude", "Codex"].filter { history[$0]?.isEmpty == false }
        let product = products.contains(store.planProduct) ? store.planProduct : products.first ?? ""
        let weeks = history[product] ?? []
        let latestFull = weeks.compactMap { $0.perFull }.first
        let firstReading = r.readings.filter { $0.product == product }.map { $0.at }.min()
        return Group {
            if !products.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        cap("Plan weeks")
                        Spacer()
                        ForEach(products, id: \.self) { p in tab(p, p == product) { store.planProduct = p } }
                    }
                    HStack {
                        cap("Week"); Spacer()
                        cap("API est.").frame(width: fs(74), alignment: .trailing)
                        cap("Limits").frame(width: fs(52), alignment: .trailing)
                        cap("Resets").frame(width: fs(48), alignment: .trailing)
                    }
                    ForEach(weeks) { w in
                        let full = w.hasUnpricedUsage ? nil : (w.perFull ?? latestFull)
                        let limitUse = full.flatMap { full in w.cost.map { $0 / full } }
                        HStack {
                            Text("\(dayLabel(w.start)) – \(dayLabel(w.end))\(w.end > Date() ? " ·" : "")")
                            Spacer()
                            Text(historyCost(w.cost, partial: w.hasUnpricedUsage)).frame(width: fs(74), alignment: .trailing)
                                .help(w.hasUnpricedUsage ? "Some models in this week have no price" : "API list-price estimate from available logs")
                            Text(limitUse.map { "\(w.perFull == nil ? "≈" : "")\(String(format: "%.1f×", $0))" } ?? "—")
                                .frame(width: fs(52), alignment: .trailing)
                                .foregroundColor(w.perFull == nil ? .secondary : .primary)
                                .help(w.perFull.map { "100% was worth ≈ \(usd($0)) this week" } ?? "No readings this week; uses the latest known 100% value")
                            Text(w.resets > 0 ? "↻\(w.resets)" : "—").frame(width: fs(48), alignment: .trailing)
                                .foregroundColor(w.resets > 0 ? accent : .secondary)
                        }
                        .font(.system(size: fs(11.5))).monospacedDigit()
                    }
                    Text("Limits = week's cost ÷ what 100% was worth that week (≈ = latest known value). Resets are detected from readings\(firstReading.map { " since \(dayLabel($0))" } ?? "").")
                        .font(.system(size: fs(9.5))).foregroundColor(.secondary)
                }
                .card()
            }
        }
    }

    /// History page: each month in the available logs, newest first.
    func monthly(_ r: Report) -> some View {
        let first = cal.dateInterval(of: .month, for: r.firstDay ?? today())!.start
        let all = Span(from: first, to: tomorrow(), days: 1, title: "All time", unit: .month)
        let es = scoped(r, all.from, all.to)
        let byMonth = Dictionary(grouping: es, by: { cal.dateInterval(of: .month, for: $0.day)!.start })
        let months = byMonth.keys.sorted(by: >)
        let total = sum(es)
        let partialTotal = es.contains { $0.device == thisMac && r.unpriced.contains($0.model) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                cap("Monthly usage")
                    .help("Available logs for \(scopeName). Local history includes the last \(scanDays) days.")
                Spacer()
                if !es.isEmpty {
                    cap("\(tok(total.tokens)) tokens")
                    cap("API est. \(historyCost(total.cost, partial: partialTotal))")
                        .help(partialTotal ? "Models without prices are included in tokens but excluded from cost" : "API list-price estimate")
                }
            }
            if !r.codexHistoryStatus.isEmpty {
                Label(r.codexHistoryStatus, systemImage: "exclamationmark.triangle")
                    .font(.system(size: fs(10))).foregroundColor(.orange)
            }
            if months.isEmpty && !r.loadingCodexHistory {
                Text("No saved usage for this selection").font(.system(size: fs(11))).foregroundColor(.secondary)
            } else if !months.isEmpty {
                trend(r, all)
                Divider().opacity(0.6)
                VStack(spacing: 0) {
                    ForEach(months, id: \.self) { m in
                        let entries = byMonth[m] ?? []
                        let row = sum(entries)
                        let partial = entries.contains { $0.device == thisMac && r.unpriced.contains($0.model) }
                        HStack {
                            Text(m.formatted(.dateTime.month(.wide).year()))
                            Spacer()
                            Text(tok(row.tokens)).foregroundColor(.secondary).frame(width: fs(70), alignment: .trailing)
                            Text(historyCost(row.cost, partial: partial)).frame(width: fs(87), alignment: .trailing)
                                .help(partial ? "Models without prices are included in tokens but excluded from cost" : "API list-price estimate")
                        }
                        .font(.system(size: fs(11.5))).monospacedDigit().padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .card()
    }

    func dot(_ day: Date, _ v: Double, _ maxV: Double, _ inRange: Bool) -> some View {
        let size: CGFloat = v > 0 && maxV > 0 ? 3 + 7 * CGFloat((v / maxV).squareRoot()) : 2.5
        return ZStack {
            if day <= today() {
                Circle().fill(v > 0 ? accent : Color.primary.opacity(0.25))
                    .frame(width: size, height: size).opacity(v == 0 || inRange ? 1 : 0.4)
                if pickedDay == day { Circle().strokeBorder(accent, lineWidth: 1).frame(width: 13, height: 13) }
            }
        }
        .frame(width: 13, height: 13)
        .contentShape(Rectangle())
        .help(day <= today() ? "\(dayLabel(day)) · \(store.metric == "tokens" ? tok(v) : store.metric == "time" ? duration(v) : usd(v))" : "")
        .onTapGesture { if day <= today() { store.pickedDay = pickedDay == day ? nil : day } }
    }

    func stat(_ label: String, _ value: String, _ sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            cap(label)
            Text(value).font(.system(size: fs(15), weight: .regular).width(.expanded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let sub = sub { Text(sub).font(.system(size: fs(9.5))).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: breakdown

    func breakdown(_ r: Report) -> some View {
        let g = store.span
        let es = periodEntries(r, g)
        let cur = sum(es)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                tab("Provider", store.mode == "provider") { store.mode = "provider" }
                tab("Model", store.mode == "model") { store.mode = "model" }
                tab("Project", store.mode == "project") { store.mode = "project" }
                if r.devices.count > 1 { tab("Device", store.mode == "device") { store.mode = "device" } }
                tab("Day", store.mode == "day") { store.mode = "day" }
                Spacer()
            }
            if es.isEmpty {
                Text("No usage in this period").font(.system(size: fs(11))).foregroundColor(.secondary)
            } else if store.mode == "day" {
                days(r, g)
            } else {
                let byProvider = store.mode == "provider", byProject = store.mode == "project", byDevice = store.mode == "device"
                let groups = Dictionary(grouping: es, by: {
                    byProvider ? $0.provider : byProject ? ($0.project.isEmpty ? "?" : $0.project) : byDevice ? $0.device : $0.model
                })
                    .map { (key: $0.key, es: $0.value, row: sum($0.value)) }
                    .sorted { $0.row.cost > $1.row.cost }
                ForEach(Array(groups.prefix(8)), id: \.key) { grp in
                    Button {
                        if byProvider { store.provider = grp.key; store.model = nil }
                        else if byProject { store.project = grp.key == "?" ? nil : grp.key }
                        else if byDevice { store.device = grp.key }
                        else { store.model = grp.key }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if byProject || byDevice {
                                    Image(systemName: byDevice ? "desktopcomputer" : "folder").font(.system(size: fs(9))).foregroundColor(.secondary)
                                } else {
                                    Circle().fill(providerColor(byProvider ? grp.key : providerOf(grp.key)))
                                        .frame(width: 6, height: 6)
                                }
                                Text(grp.key).font(.system(size: fs(12), weight: .medium)).lineLimit(1)
                                    .truncationMode(.middle).help(grp.key)
                                Spacer()
                                Text(tok(grp.row.tokens)).font(.system(size: fs(10.5))).foregroundColor(.secondary)
                                Text(cur.cost > 0 ? String(format: "%.0f%%", grp.row.cost / cur.cost * 100) : "—")
                                    .font(.system(size: fs(10.5))).foregroundColor(.secondary).frame(minWidth: fs(30), alignment: .trailing)
                                Text(r.unpriced.contains(grp.key) ? "—" : usd(grp.row.cost))
                                    .font(.system(size: fs(12), weight: .semibold)).frame(minWidth: fs(54), alignment: .trailing)
                            }
                            .monospacedDigit()
                            bar(cur.cost > 0 ? grp.row.cost / cur.cost : 0)
                            if byProvider || byDevice { Text(modelSplit(grp.es)).font(.system(size: fs(10))).foregroundColor(.secondary).lineLimit(2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if groups.count > 8 {
                    let rest = groups.dropFirst(8)
                    Text("+\(rest.count) more · \(usd(rest.reduce(0) { $0 + $1.row.cost }))")
                        .font(.system(size: fs(10.5))).foregroundColor(.secondary)
                }
            }
        }
        .card()
    }

    /// "claude-opus-5-5 89% · claude-sonnet-5-5 11%"
    func modelSplit(_ es: [Entry]) -> String {
        let total = es.reduce(0) { $0 + $1.row.cost }
        return Dictionary(grouping: es, by: { $0.model }).mapValues { $0.reduce(0) { $0 + $1.row.cost } }
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \(total > 0 ? Int(($0.value / total * 100).rounded()) : 0)%" }
            .joined(separator: " · ")
    }

    /// Daily table for the selected range, newest first; click a row to focus that day.
    /// Long ranges list only days with usage.
    func days(_ r: Report, _ g: Span) -> some View {
        let byDay = Dictionary(grouping: periodEntries(r, g), by: { $0.day }).mapValues { sum($0) }
        let first = cal.startOfDay(for: g.from), last = cal.startOfDay(for: g.to.addingTimeInterval(-1))
        let count = (cal.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        let rows = (0..<count).map { cal.date(byAdding: .day, value: -$0, to: last)! }
            .map { (day: $0, row: byDay[$0] ?? Row()) }
            .filter { g.days <= 90 || $0.row.tokens > 0 }
        return VStack(spacing: 0) {
            HStack { cap("Date"); Spacer(); cap("Tokens").frame(width: fs(70), alignment: .trailing); cap("Cost").frame(width: fs(64), alignment: .trailing) }
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.day) { x in
                        Button { store.pickedDay = x.day } label: {
                            HStack {
                                Text(g.unit == .month ? x.day.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
                                     : x.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                Spacer()
                                Text(x.row.tokens > 0 ? tok(x.row.tokens) : "—").foregroundColor(.secondary)
                                    .frame(width: fs(70), alignment: .trailing)
                                Text(x.row.tokens > 0 ? usd(x.row.cost) : "—").frame(width: fs(64), alignment: .trailing)
                            }
                            .font(.system(size: fs(11.5))).monospacedDigit()
                            .padding(.vertical, 5)
                            .foregroundColor(pickedDay == x.day ? accent : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(height: min(CGFloat(rows.count) * 27, 190))
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            if let r = store.report {
                if r.loadingCodexHistory {
                    Text("Reading compressed Codex history…").lineLimit(1)
                } else if !r.otherDevicesStatus.isEmpty {
                    Label(r.otherDevicesStatus, systemImage: "exclamationmark.triangle").foregroundColor(.orange).lineLimit(1)
                        .help(r.otherDevicesStatus)
                } else {
                    cap(r.updated.formatted(date: .omitted, time: .shortened)).help("Last refresh")
                }
            }
            Spacer()
            Button { prefs.stepText(-1) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller text (⌘−)").keyboardShortcut("-", modifiers: .command)
                .disabled(prefs.textScale == Prefs.textScales.first)
            Button { prefs.stepText(1) } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger text (⌘+)").keyboardShortcut("=", modifiers: .command)
                .disabled(prefs.textScale == Prefs.textScales.last)
            if inPopover {
                if store.refreshing {
                    ProgressView().controlSize(.mini).frame(width: fs(14))
                } else {
                    Button { store.refresh(forceCodexRefresh: true) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }
                Button { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } label: {
                    Image(systemName: "ellipsis.circle")
                }.help("More")
            }
        }
        .font(.system(size: fs(10))).foregroundColor(.secondary)
        .buttonStyle(.borderless)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $prefs.menuBarFormat) {
                    ForEach(menuBarFormats, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("Plan limit alert", selection: $prefs.alertThreshold) {
                    ForEach(alertThresholds, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("Color the menu bar at the alert level", isOn: $prefs.colorMenuBar)
                Text("From this level the fullest plan limit appears next to the cost.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
            }
            Section("Appearance") {
                Picker("Panel text", selection: $prefs.textScale) {
                    Text("Default").tag(CGFloat(1.0))
                    Text("Large").tag(CGFloat(1.15))
                    Text("Larger").tag(CGFloat(1.3))
                }
                .pickerStyle(.segmented)
                Toggle("Solid background (clearer over light windows)", isOn: $prefs.solidBackground)
            }
            Section("Overview shows") {
                Toggle("One-line summary", isOn: $prefs.showInsight)
                Toggle("Tokens, calls and active time", isOn: $prefs.showDetails)
                Toggle("Trend chart", isOn: $prefs.showTrend)
                Toggle("Split chart by provider", isOn: $prefs.splitByProvider)
                Toggle("Plan limits", isOn: $prefs.showLimits)
                Toggle("Plan limit pace and reset details", isOn: $prefs.showLimitDetails)
                Toggle("Period stats (active days, busiest day, cache saved)", isOn: $prefs.showPeriodStats)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Toggle("Show widget on desktop", isOn: $prefs.showDesktopWidget)
            }
            Section("Plan limits") {
                Toggle("Read Codex limits live", isOn: $prefs.liveCodex)
                Text("Asks OpenAI for your current Codex usage with the Codex login on this Mac (at most every 2 minutes). The login is never stored or sent anywhere else. Off: Tokenly uses Codex's logs and Vibe Usage's saved reading.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
                Toggle("Read Claude limits live", isOn: $prefs.liveClaude)
                Text("Briefly runs Claude Code in a safe, tool-less mode to ask for your plan usage (at most every 5 minutes). No prompt is sent and no tokens are used. Off: Tokenly uses Claude Code's cached reading.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
            }
            Section("Plan prices") {
                TextField("Claude, $ per month", value: $prefs.claudePlanPrice, format: .number)
                TextField("Codex, $ per month", value: $prefs.codexPlanPrice, format: .number)
                Text("0 = guess from the plan badge (Claude Max / Codex Pro $200, Claude Pro / ChatGPT Plus $20). Used for \"last 30 days worth N×\" under each plan.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
            }
            Section("Other devices") {
                Toggle("Include my other devices from Vibe Usage", isOn: $prefs.includeOtherDevices)
                    .disabled(VibeImporter.config() == nil && !prefs.includeOtherDevices)
                Text(VibeImporter.config() == nil
                     ? "Link the Vibe Usage app on this Mac first. Tokenly then reads your account's history with the key it stored."
                     : "Read-only: downloads your account's usage from vibecafe.ai with the key the Vibe Usage app stored on this Mac, back to your first synced day. Nothing is uploaded. This Mac's numbers always come from its own logs.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
            }
            Section("Pricing") {
                Text("Costs are estimated at API list prices. Override or add models in ~/.config/tokenly/prices.json (USD per 1M tokens: input, output, cache read, cache write 5m, cache write 1h). The CLI reads the same file.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
                Button("Edit Prices…") { openPricesFile() }
            }
            Section("About") {
                Text("Tokenly \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") reads the logs Claude Code and Codex write on this Mac. Nothing is uploaded; the only network request is the optional other-devices download.")
                    .font(.system(size: fs(11))).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Logo

/// The Tokenly mark, on an 11×10 pixel grid (y = 0 at the top): a terminal block with a green ">" prompt,
/// a pixel "T" and a green "_" cursor.
enum Mark {
    static let w = 11, h = 10
    static let prompt = [(1, 2), (2, 3), (1, 4)]
    static let t = [(4, 2), (5, 2), (6, 2), (7, 2), (8, 2), (6, 3), (6, 4), (6, 5), (6, 6), (6, 7)]
    static let cursor = [(8, 7), (9, 7)]
    static let green = NSColor(red: 0.49, green: 1.0, blue: 0.70, alpha: 1)
}

/// Draws the mark into a `px` square. `template`: solid block with the glyphs cut out (menu bar).
/// `tile`: the app icon, with the mark on a light rounded tile. Otherwise: the panel header version.
func drawLogo(px: CGFloat, template: Bool = false, tile: Bool = false) {
    guard let ctx = NSGraphicsContext.current else { return }
    var area = px
    if tile {
        ctx.shouldAntialias = true
        let r = NSRect(x: px * 0.1, y: px * 0.1, width: px * 0.8, height: px * 0.8)
        let path = NSBezierPath(roundedRect: r, xRadius: px * 0.18, yRadius: px * 0.18)
        NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.89, alpha: 1))!.draw(in: path, angle: -90)
        area = px * 0.5
    }
    ctx.shouldAntialias = false
    let cell = max(0.5, (area * 2 / CGFloat(Mark.w)).rounded(.down) / 2) // half points = whole pixels on Retina
    let ox = ((px - cell * CGFloat(Mark.w)) / 2).rounded(.down), oy = ((px - cell * CGFloat(Mark.h)) / 2).rounded(.down)
    let rect = { (x: Int, y: Int) in NSRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(Mark.h - 1 - y) * cell, width: cell, height: cell) }
    let block = NSRect(x: ox, y: oy, width: cell * CGFloat(Mark.w), height: cell * CGFloat(Mark.h))
    (template ? NSColor.black : tile ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    block.fill()
    for (x, y) in Mark.t {
        if template { rect(x, y).fill(using: .clear) }
        else { (tile ? NSColor.white : NSColor(white: 0.09, alpha: 1)).setFill(); rect(x, y).fill() }
    }
    for (x, y) in Mark.prompt + Mark.cursor {
        if template { rect(x, y).fill(using: .clear) }
        else { (tile ? Mark.green : NSColor(red: 0.12, green: 0.62, blue: 0.36, alpha: 1)).setFill(); rect(x, y).fill() }
    }
}

func logoImage(points: CGFloat, template: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: points, height: points), flipped: false) { _ in
        drawLogo(px: points, template: template)
        return true
    }
    img.isTemplate = template
    return img
}

/// `Tokenly --make-iconset dir` writes the app icon PNGs that build.sh turns into Tokenly.icns.
func makeIconsetIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--make-iconset"), i + 1 < args.count else { return }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawLogo(px: CGFloat(px), tile: true)
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }
    exit(0)
}

// MARK: - Window helpers

/// Transparent strip: drag to move the window, right-click for the menu.
struct DragHandle: NSViewRepresentable {
    let menu: NSMenu
    func makeNSView(context: Context) -> NSView { let v = DragView(); v.contextMenu = menu; return v }
    func updateNSView(_ v: NSView, context: Context) {}
}

final class DragView: NSView {
    var contextMenu: NSMenu?
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
}

/// Let clicks on the widget act immediately even though the app is in the background.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws inside the status item while letting clicks reach the button underneath.
final class PassthroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let prefs = Prefs.shared
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hosting: NSView!
    let popover = NSPopover()
    var settingsWindow: NSWindow?
    var stackedView: PassthroughHostingView<AnyView>?
    var sizeSub: AnyCancellable?
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TM"
        statusItem.button?.image = logoImage(points: 17, template: true)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let hc = NSHostingController(rootView: WidgetView(store: store, menu: menu, inPopover: true))
        hc.sizingOptions = .preferredContentSize
        popover.contentViewController = hc
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        store.onUpdate = { [weak self] r in
            self?.setStatusTitle(r)
            self?.snapshotIfRequested()
        }
        prefs.onChange = { [weak self] in self?.applyPrefs() }
        prefs.onDataChange = { [weak self] in
            if self?.prefs.includeOtherDevices == false { self?.store.device = nil }
            self?.store.refresh()
        }
        // Any data or selection change can change the content height.
        sizeSub = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
        store.refresh()
        Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in self?.store.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.store.refresh() }
    }

    func buildWindow() {
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        window.contentView = blur

        hosting = ClickThroughHostingView(rootView: WidgetView(store: store, menu: menu))
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)

        let name = "TokenlyWidget"
        if !window.setFrameUsingName(name), let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 380, y: screen.maxY - 40))
        }
        window.setFrameAutosaveName(name)
        if prefs.solidBackground { blur.layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.96).cgColor }
        if prefs.showDesktopWidget || CommandLine.arguments.contains("--snapshot") { window.orderFront(nil) }
    }

    func applyPrefs() {
        if let r = store.report { setStatusTitle(r) }
        window.contentView?.layer?.backgroundColor = prefs.solidBackground ? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.96).cgColor : nil
        if prefs.showDesktopWidget != window.isVisible {
            if prefs.showDesktopWidget { window.orderFront(nil) } else { window.orderOut(nil) }
        }
    }

    /// Menu bar title per Settings, plus the fullest plan limit once it passes the alert threshold.
    func setStatusTitle(_ r: Report) {
        let t = r.total(from: today(), to: tomorrow())
        let q = r.fullestQuota
        let qText = q.map { "\($0.product) \(Int($0.peak.rounded()))%" }
        var title: String
        switch prefs.menuBarFormat {
        case "tokens": title = tok(t.tokens)
        case "both": title = "\(usd(t.cost)) · \(tok(t.tokens))"
        case "quota": title = qText ?? usd(t.cost)
        default: title = usd(t.cost)
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        var alert: NSColor?
        if let q = q, let qText = qText, prefs.alertThreshold > 0, q.peak >= Double(prefs.alertThreshold) {
            if prefs.menuBarFormat != "quota" { title += " · \(qText)" }
            if prefs.colorMenuBar {
                alert = q.peak >= 90 ? NSColor.systemRed : NSColor.systemOrange
                attrs[.foregroundColor] = alert
            }
        }
        guard let button = statusItem.button else { return }
        if prefs.menuBarFormat == "stacked" {
            // Two small lines in one status item, drawn by SwiftUI (clicks pass through to the button).
            let top = usd(t.cost) + (title.contains("%") ? " · \(Int((q?.peak ?? 0).rounded()))%" : "")
            let view = AnyView(HStack(spacing: 3) {
                Image(nsImage: logoImage(points: 17, template: true)).renderingMode(.template)
                VStack(alignment: .leading, spacing: -2) {
                    Text(top).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(alert.map { Color(nsColor: $0) } ?? .primary)
                    Text(tok(t.tokens)).font(.system(size: 8.5).monospacedDigit()).foregroundColor(.secondary)
                }
            }.fixedSize())
            if stackedView == nil {
                stackedView = PassthroughHostingView(rootView: view)
                button.addSubview(stackedView!)
            } else {
                stackedView!.rootView = view
            }
            button.title = ""
            button.image = nil
            let size = stackedView!.fittingSize
            statusItem.length = size.width + 8
            stackedView!.frame = NSRect(x: 4, y: (button.bounds.height - size.height) / 2, width: size.width, height: size.height)
            return
        }
        stackedView?.removeFromSuperview()
        stackedView = nil
        statusItem.length = NSStatusItem.variableLength
        button.image = logoImage(points: 17, template: true)
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    /// Debug: `Tokenly --snapshot out.png [today|24h|week|month|90d|dayN] [--popover] [provider=…] [model=…]
    /// [project=…] [mode=…] [hover=N] [--settings]` renders the panel (or Settings) to a PNG and quits.
    func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let mode = i + 2 < args.count ? args[i + 2] : "today"
        if mode.hasPrefix("day"), let n = Int(mode.dropFirst(3)) { store.pickedDay = daysAgo(n) }
        else { store.preset = ["24h": .h24, "week": .week, "month": .month, "90d": .quarter, "all": .all, "reset": .codexReset][mode] ?? .today }
        let arg: (String) -> String? = { k in args.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
        if let v = arg("provider") { store.provider = v }
        if let v = arg("model") { store.model = v }
        if let v = arg("mode") { store.mode = v }
        if let v = arg("project") { store.project = v }
        if let v = arg("hover") { store.hover = Int(v) }
        if let v = arg("device") { store.device = v }
        if let v = arg("page") { prefs.expanded = v != "overview" }
        if mode == "custom" {
            store.preset = .custom
            if let v = arg("from"), let d = parseDate(v + "T00:00:00Z") { store.customFrom = cal.startOfDay(for: d.addingTimeInterval(43200)) }
            if let v = arg("to"), let d = parseDate(v + "T00:00:00Z") { store.customTo = cal.startOfDay(for: d.addingTimeInterval(43200)) }
        }
        window.contentView?.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        if let blur = window.contentView, args.contains("--popover") || args.contains("--settings") {
            hosting.removeFromSuperview()
            hosting = args.contains("--settings")
                ? ClickThroughHostingView(rootView: AnyView(SettingsView(prefs: prefs)))
                : ClickThroughHostingView(rootView: AnyView(WidgetView(store: store, menu: menu, inPopover: true)))
            hosting.frame = blur.bounds
            hosting.autoresizingMask = [.width, .height]
            blur.addSubview(hosting)
            fit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.fit()
            guard let v = self.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }

    /// Resize to the SwiftUI content, keeping the top-left corner fixed.
    func fit() {
        let size = hosting.fittingSize
        let f = window.frame
        guard size.height > 0, abs(f.height - size.height) > 0.5 || abs(f.width - size.width) > 0.5 else { return }
        window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    // Rebuilt every time it opens so the summary and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let r = store.report {
            let t = r.total(from: today(), to: tomorrow()).cost
            let m = r.total(from: daysAgo(29), to: tomorrow()).cost
            menu.addItem(withTitle: "Today \(usd(t)) · 30 days \(usd(m))", action: nil, keyEquivalent: "")
            if let q = r.fullestQuota { menu.addItem(withTitle: "\(q.product) plan \(Int(q.peak.rounded()))% used", action: nil, keyEquivalent: "") }
            menu.addItem(.separator())
        }
        add(menu, "Refresh", #selector(refresh), "r")
        menu.addItem(submenu("Menu Bar Shows", menuBarFormats.map { ($0.0, $0.1 as Any, prefs.menuBarFormat == $0.1) }, #selector(setFormat(_:))))
        menu.addItem(submenu("Plan Limit Alert", alertThresholds.map { ($0.0, $0.1 as Any, prefs.alertThreshold == $0.1) }, #selector(setThreshold(_:))))
        menu.addItem(submenu("Text Size", zip(["Default", "Large", "Larger"], Prefs.textScales).map { ($0.0, $0.1 as Any, prefs.textScale == $0.1) },
                             #selector(setTextScale(_:))))
        add(menu, "Show on Desktop", #selector(toggleWidget), "", on: prefs.showDesktopWidget)
        add(menu, "Launch at Login", #selector(toggleLogin), "", on: prefs.launchAtLogin)
        add(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator())
        add(menu, "Quit Tokenly", #selector(NSApplication.terminate(_:)), "q")
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String, on: Bool = false) {
        let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        item.target = sel == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.state = on ? .on : .off
    }

    func submenu(_ title: String, _ items: [(String, Any, Bool)], _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, value, on) in items {
            let item = sub.addItem(withTitle: t, action: sel, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
        }
        parent.submenu = sub
        return parent
    }

    @objc func refresh() { store.refresh(forceCodexRefresh: true) }
    @objc func setFormat(_ item: NSMenuItem) { if let v = item.representedObject as? String { prefs.menuBarFormat = v } }
    @objc func setThreshold(_ item: NSMenuItem) { if let v = item.representedObject as? Int { prefs.alertThreshold = v } }
    @objc func toggleWidget() { prefs.showDesktopWidget.toggle() }
    @objc func setTextScale(_ item: NSMenuItem) { if let v = item.representedObject as? CGFloat { prefs.textScale = v } }
    @objc func toggleLogin() { prefs.launchAtLogin.toggle() }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(prefs: prefs)))
            w.title = "Tokenly Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Left click: usage panel. Right click: menu.
    @objc func statusClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            if let r = store.report, Date().timeIntervalSince(r.updated) > 60 { store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// One-time move from the TokenMeter name: settings, price overrides and the other-devices cache.
func migrateFromTokenMeter() {
    let ud = UserDefaults.standard
    guard !ud.bool(forKey: "migratedFromTokenMeter") else { return }
    if let old = UserDefaults(suiteName: "io.github.longado.tokenmeter") {
        for (k, v) in old.dictionaryRepresentation() where ud.object(forKey: k) == nil
            && !k.hasPrefix("NS") && !k.hasPrefix("Apple") && !k.hasPrefix("com.apple") {
            ud.set(v, forKey: k)
        }
    }
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let oldPrices = home.appendingPathComponent(".config/tokenmeter/prices.json")
    if fm.fileExists(atPath: oldPrices.path) && !fm.fileExists(atPath: pricesOverrideURL.path) {
        try? fm.createDirectory(at: pricesOverrideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: oldPrices, to: pricesOverrideURL)
    }
    let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    try? fm.moveItem(at: caches.appendingPathComponent("TokenMeter"), to: caches.appendingPathComponent("Tokenly"))
    ud.set(true, forKey: "migratedFromTokenMeter")
}

#if TOKENLY_HISTORY_TESTS
try testUsageHistory()
#else
makeIconsetIfRequested()
signal(SIGPIPE, SIG_IGN) // a probe that exits early must not take the app down with it
migrateFromTokenMeter()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
