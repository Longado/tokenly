// TokenMeter.app: menu bar panel (and optional desktop widget) showing local token usage and
// API-equivalent cost for Claude Code and Codex CLI. Reads local logs only.
import AppKit
import Combine
import ServiceManagement
import SwiftUI

let scanDays = 98 // 13-week activity grid (+ partial week); also covers the 30-day "vs previous" delta
let refreshSeconds: TimeInterval = 300

// USD per 1M tokens: input, output, cache_read, cache_write_5m, cache_write_1h
// Keep in sync with PRICES in tokenmeter.py.
let prices: [String: [Double]] = [
    "claude-fable-5-2": [8, 40, 0.20, 10, 16],
    "claude-opus-5-5": [4, 20, 0.20, 5, 8],
    "claude-sonnet-5-5": [2, 10, 0.10, 2.5, 4],
    "claude-haiku-5-5": [0.10, 0.50, 0.01, 0.125, 0.20],
    "gpt-6.1-sol": [2, 10, 0.10, 2.5, 2.5],
]

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

/// Usage of one model on one tool on one local day.
struct Entry {
    let day: Date, tool: String, model: String
    var row: Row
    var provider: String { providerOf(model) }
}

struct Report {
    var entries: [Entry] = []
    var unpriced: Set<String> = []
    var updated = Date()

    func entries(from: Date, to: Date) -> [Entry] { entries.filter { $0.day >= from && $0.day <= to } }
    func total(from: Date, to: Date) -> Row {
        entries(from: from, to: to).reduce(into: Row()) { $0.add($1.row) }
    }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
let cal = Calendar.current
func today() -> Date { cal.startOfDay(for: Date()) }
func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today())! }

final class Scanner {
    let since = daysAgo(scanDays - 1)
    var buckets: [String: Entry] = [:]
    var unpriced = Set<String>()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    func add(_ ts: Any?, _ tool: String, _ model: String,
             _ i: Double, _ o: Double, _ cr: Double, _ cw: Double, _ cw1h: Double = 0) {
        guard let s = ts as? String, let date = isoFrac.date(from: s) ?? iso.date(from: s), date >= since,
              i + o + cr + cw > 0 else { return }
        let p = prices[model] ?? [0, 0, 0, 0, 0]
        if prices[model] == nil { unpriced.insert(model) }
        let cost = (i * p[0] + o * p[1] + cr * p[2] + (cw - cw1h) * p[3] + cw1h * p[4]) / 1e6
        let r = Row(input: i, output: o, cacheRead: cr, cacheWrite: cw, cost: cost, saved: cr * (p[0] - p[2]) / 1e6, calls: 1)
        let day = cal.startOfDay(for: date)
        let key = "\(day.timeIntervalSince1970)|\(tool)|\(model)"
        buckets[key, default: Entry(day: day, tool: tool, model: model, row: Row())].row.add(r)
    }

    /// Lines of every .jsonl under `dir` modified within the scan window.
    func files(under dir: String) -> [[Substring]] {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [[Substring]] = []
        for case let f as URL in e where f.pathExtension == "jsonl" {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod = mod, mod < since { continue }
            if let s = try? String(contentsOf: f, encoding: .utf8) { out.append(s.split(separator: "\n")) }
        }
        return out
    }

    func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    func scanClaude(_ root: String) {
        var seen = Set<String>()
        for file in files(under: root + "/projects") {
            for line in file where line.contains("\"usage\"") {
                guard let d = json(line), let m = d["message"] as? [String: Any],
                      let u = m["usage"] as? [String: Any] else { continue }
                // the same message can be logged several times
                if !seen.insert("\(m["id"] ?? "")|\(d["requestId"] ?? "")").inserted { continue }
                let cc = u["cache_creation"] as? [String: Any]
                add(d["timestamp"], "Claude Code", m["model"] as? String ?? "?",
                    num(u["input_tokens"]), num(u["output_tokens"]),
                    num(u["cache_read_input_tokens"]), num(u["cache_creation_input_tokens"]),
                    num(cc?["ephemeral_1h_input_tokens"]))
            }
        }
    }

    func scanCodex(_ root: String) {
        for file in files(under: root + "/sessions") {
            var model = "?"
            for line in file where line.contains("turn_context") || line.contains("token_count") {
                guard let d = json(line), let p = d["payload"] as? [String: Any] else { continue }
                if d["type"] as? String == "turn_context", let m = p["model"] as? String {
                    model = m
                } else if p["type"] as? String == "token_count",
                          let u = (p["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] {
                    // input includes cached tokens
                    let c = num(u["cached_input_tokens"])
                    add(d["timestamp"], "Codex", model, num(u["input_tokens"]) - c, num(u["output_tokens"]),
                        c, num(u["cache_write_input_tokens"]))
                }
            }
        }
    }

    static func run() -> Report {
        let env = ProcessInfo.processInfo.environment
        let s = Scanner()
        s.scanClaude(env["CLAUDE_CONFIG_DIR"] ?? "~/.claude")
        s.scanCodex(env["CODEX_HOME"] ?? "~/.codex")
        return Report(entries: Array(s.buckets.values), unpriced: s.unpriced)
    }
}

// MARK: - Formatting

func usd(_ v: Double) -> String { v >= 1000 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
func tok(_ v: Double) -> String {
    v >= 1e9 ? String(format: "%.1fB", v / 1e9) : v >= 1e6 ? String(format: "%.1fM", v / 1e6) : v >= 1e3 ? String(format: "%.0fK", v / 1e3) : String(format: "%.0f", v)
}
func dayLabel(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

// MARK: - Store

final class Store: ObservableObject {
    @Published var report: Report?
    @Published var preset = Preset.today
    @Published var pickedDay: Date?
    @Published var provider: String? // nil = all providers
    @Published var model: String? // nil = all models
    @Published var mode = "provider" // breakdown: provider | model | day
    var onUpdate: ((Report) -> Void)?
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let r = Scanner.run()
            DispatchQueue.main.async { self.report = r; self.onUpdate?(r) }
        }
    }
}

// MARK: - Widget UI

let accent = Color(red: 0.67, green: 0.58, blue: 1.0)
let heatWeeks = 13

enum Preset: String, CaseIterable, Identifiable {
    case today = "Today", week = "7D", month = "30D"
    var id: String { rawValue }
    var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
    var title: String { self == .today ? "Today" : self == .week ? "Last 7 days" : "Last 30 days" }
}

/// Small uppercase, letter-spaced section label.
func cap(_ s: String) -> some View {
    Text(s.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1.1).foregroundColor(.secondary)
        .lineLimit(1)
}

func bar(_ share: Double, _ color: Color = accent) -> some View {
    GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(color).frame(width: max(0, geo.size.width * min(share, 1)))
        }
    }
    .frame(height: 3)
}

/// Text tab with an underline when selected.
func tab(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
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

struct WidgetView: View {
    @ObservedObject var store: Store
    let menu: NSMenu
    var inPopover = false

    var pickedDay: Date? { store.pickedDay }
    var provider: String? { store.provider }

    /// Selected range: a clicked day, or the preset ending today.
    var range: (from: Date, to: Date, days: Int, title: String) {
        if let d = pickedDay { return (d, d, 1, d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        return (daysAgo(store.preset.days - 1), today(), store.preset.days, store.preset.title)
    }
    var scopeName: String { store.model ?? provider ?? "All providers" }

    /// Entries in [from, to] for the selected provider/model (all when nil).
    func scoped(_ r: Report, _ from: Date, _ to: Date) -> [Entry] {
        r.entries(from: from, to: to).filter {
            (provider == nil || $0.provider == provider) && (store.model == nil || $0.model == store.model)
        }
    }
    func sum(_ es: [Entry]) -> Row { es.reduce(into: Row()) { $0.add($1.row) } }
    /// Providers that have any usage in the scan window, in fixed order.
    var present: [(name: String, color: Color)] {
        let seen = Set(store.report?.entries.map { $0.provider } ?? [])
        return providers.filter { seen.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let r = store.report {
                filters(r)
                hero(r)
                activity(r)
                breakdown(r)
                if !r.unpriced.isEmpty {
                    Label("No price for \(r.unpriced.sorted().joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundColor(.orange)
                }
            } else {
                Text("Scanning logs…").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: header & filters

    var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").foregroundColor(accent)
                Text("TOKENMETER").font(.system(size: 12, weight: .semibold).width(.expanded)).tracking(1.4)
            }
            .contentShape(Rectangle())
            .overlay(inPopover ? nil : DragHandle(menu: menu)) // desktop: drag to move, right-click for menu
            Spacer()
            ForEach(Preset.allCases) { p in
                tab(p.rawValue, pickedDay == nil && store.preset == p) { store.preset = p; store.pickedDay = nil }
            }
        }
    }

    func filters(_ r: Report) -> some View {
        HStack(spacing: 6) {
            chip("All", nil, .primary)
            ForEach(present, id: \.name) { chip($0.name, $0.name, $0.color) }
            Spacer(minLength: 4)
            modelPicker(r)
        }
    }

    func chip(_ label: String, _ value: String?, _ color: Color) -> some View {
        let on = provider == value
        return Button { store.provider = value; store.model = nil } label: {
            HStack(spacing: 5) {
                if value != nil { Circle().fill(color).frame(width: 6, height: 6) }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
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
        .pickerStyle(.menu).labelsHidden().controlSize(.small).frame(maxWidth: 130)
    }

    // MARK: hero

    func hero(_ r: Report) -> some View {
        let g = range
        let es = scoped(r, g.from, g.to)
        let cur = sum(es)
        let prev = sum(scoped(r, cal.date(byAdding: .day, value: -g.days, to: g.from)!,
                              cal.date(byAdding: .day, value: -1, to: g.from)!))
        let inputSide = cur.input + cur.cacheRead + cur.cacheWrite
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                cap("\(g.title) · \(scopeName)")
                Spacer()
                if pickedDay != nil { tab("Clear", false) { store.pickedDay = nil } }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(usd(cur.cost)).font(.system(size: 38, weight: .light).width(.expanded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if prev.cost > 0.005 {
                    let pct = (cur.cost - prev.cost) / prev.cost * 100
                    let c: Color = pct >= 0 ? .orange : .green
                    Text(String(format: "%@ %.0f%%", pct >= 0 ? "▲" : "▼", abs(pct)))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(c)
                        .help("vs previous \(g.days == 1 ? "day" : "\(g.days) days")")
                }
            }
            Text(insight(es, cur, g.days)).font(.system(size: 12)).foregroundColor(.primary.opacity(0.85))
            Text("\(tok(cur.tokens)) tokens · \(Int(cur.calls)) calls · at list price")
                .font(.system(size: 10.5)).foregroundColor(.secondary).monospacedDigit()
            Divider().opacity(0.6)
            HStack(alignment: .top, spacing: 10) {
                mix("Input", cur.input, cur.tokens)
                mix("Output", cur.output, cur.tokens)
                mix("Cached", cur.cacheRead, cur.tokens)
                mix("Writes", cur.cacheWrite, cur.tokens)
            }
            cap("Cache hit \(inputSide > 0 ? String(format: "%.0f%%", cur.cacheRead / inputSide * 100) : "—") · saved \(usd(cur.saved))")
        }
        .card()
    }

    /// One sentence that says what the numbers mean.
    func insight(_ es: [Entry], _ cur: Row, _ days: Int) -> String {
        if cur.tokens == 0 { return "No usage in this period." }
        var s = days > 1 ? "\(usd(cur.cost / Double(days))) a day." : "\(Int(cur.calls)) calls."
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

    func mix(_ label: String, _ v: Double, _ total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            cap(label)
            Text(tok(v)).font(.system(size: 14, weight: .regular).width(.expanded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(total > 0 ? String(format: "%.1f%%", v / total * 100) : "—")
                .font(.system(size: 9.5)).foregroundColor(.secondary).monospacedDigit()
            bar(total > 0 ? v / total : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: activity

    func activity(_ r: Report) -> some View {
        let start = cal.date(byAdding: .day, value: -7 * (heatWeeks - 1),
                             to: cal.dateInterval(of: .weekOfYear, for: today())!.start)!
        let daily = Dictionary(grouping: scoped(r, start, today()), by: { $0.day })
            .mapValues { $0.reduce(0) { $0 + $1.row.cost } }
        let maxV = daily.values.max() ?? 0
        let peak = daily.max { $0.value < $1.value }
        let c7 = sum(scoped(r, daysAgo(6), today())).cost
        let c30 = sum(scoped(r, daysAgo(29), today())).cost
        let g = range
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                cap("Activity · \(heatWeeks) weeks")
                Spacer()
                if let p = peak { cap("Peak \(usd(p.value)) · \(dayLabel(p.key))") }
            }
            HStack(spacing: 0) {
                ForEach(0..<heatWeeks, id: \.self) { w in
                    let first = cal.date(byAdding: .day, value: 7 * w, to: start)!
                    let monthStart = (0..<7).contains { cal.component(.day, from: cal.date(byAdding: .day, value: $0, to: first)!) == 1 }
                    VStack(spacing: 3) {
                        Text(w == 0 || monthStart ? first.addingTimeInterval(monthStart ? 6 * 86400 : 0)
                                .formatted(.dateTime.month(.abbreviated)).uppercased() : " ")
                            .font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                            .fixedSize().frame(height: 10)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: 7 * w + d, to: start)!
                            dot(day, daily[day] ?? 0, maxV, day >= g.from && day <= g.to)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                cap("Dot size = cost that day")
                Spacer()
            }
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                stat("Last 7 days", usd(c7))
                stat("Last 30 days", usd(c30))
                stat("Daily avg", usd(c30 / 30))
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
        .help(day <= today() ? "\(dayLabel(day)) · \(usd(v))" : "")
        .onTapGesture { if day <= today() { store.pickedDay = pickedDay == day ? nil : day } }
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            cap(label)
            Text(value).font(.system(size: 15, weight: .regular).width(.expanded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: breakdown

    func breakdown(_ r: Report) -> some View {
        let g = range
        let es = scoped(r, g.from, g.to)
        let cur = sum(es)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                cap("Breakdown")
                Spacer()
                tab("Provider", store.mode == "provider") { store.mode = "provider" }
                tab("Model", store.mode == "model") { store.mode = "model" }
                tab("Day", store.mode == "day") { store.mode = "day" }
            }
            if es.isEmpty {
                Text("No usage in this period").font(.caption).foregroundColor(.secondary)
            } else if store.mode == "day" {
                days(r)
            } else {
                let byProvider = store.mode == "provider"
                let groups = Dictionary(grouping: es, by: { byProvider ? $0.provider : $0.model })
                    .map { (key: $0.key, es: $0.value, row: sum($0.value)) }
                    .sorted { $0.row.cost > $1.row.cost }
                ForEach(groups, id: \.key) { grp in
                    Button {
                        if byProvider { store.provider = grp.key; store.model = nil } else { store.model = grp.key }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle().fill(providerColor(byProvider ? grp.key : providerOf(grp.key)))
                                    .frame(width: 6, height: 6)
                                Text(grp.key).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(tok(grp.row.tokens)).font(.system(size: 10.5)).foregroundColor(.secondary)
                                Text(cur.cost > 0 ? String(format: "%.0f%%", grp.row.cost / cur.cost * 100) : "—")
                                    .font(.system(size: 10.5)).foregroundColor(.secondary).frame(minWidth: 30, alignment: .trailing)
                                Text(r.unpriced.contains(grp.key) ? "—" : usd(grp.row.cost))
                                    .font(.system(size: 12, weight: .semibold)).frame(minWidth: 54, alignment: .trailing)
                            }
                            .monospacedDigit()
                            bar(cur.cost > 0 ? grp.row.cost / cur.cost : 0)
                            if byProvider { Text(modelSplit(grp.es)).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
    func days(_ r: Report) -> some View {
        let g = range
        let rows = (0..<g.days).map { cal.date(byAdding: .day, value: -$0, to: g.to)! }
            .map { d in (day: d, row: sum(scoped(r, d, d))) }
        return VStack(spacing: 0) {
            HStack { cap("Date"); Spacer(); cap("Tokens").frame(width: 70, alignment: .trailing); cap("Cost").frame(width: 64, alignment: .trailing) }
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.day) { x in
                        Button { store.pickedDay = x.day } label: {
                            HStack {
                                Text(x.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                Spacer()
                                Text(x.row.tokens > 0 ? tok(x.row.tokens) : "—").foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                                Text(x.row.tokens > 0 ? usd(x.row.cost) : "—").frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(size: 11.5)).monospacedDigit()
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
                cap("Synced \(r.updated.formatted(date: .omitted, time: .shortened)) · local only")
            }
            Spacer()
            cap("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
            if inPopover {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } label: {
                    Image(systemName: "ellipsis.circle")
                }.help("More")
            }
        }
        .font(.caption2).foregroundColor(.secondary)
        .buttonStyle(.borderless)
    }
}

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

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hosting: NSView!
    let popover = NSPopover()
    var sizeSub: AnyCancellable?
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TM"
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "TokenMeter")
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
            self?.statusItem.button?.title = usd(r.total(from: today(), to: today()).cost)
            self?.snapshotIfRequested()
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

        let name = "TokenMeterWidget"
        if !window.setFrameUsingName(name), let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 380, y: screen.maxY - 40))
        }
        window.setFrameAutosaveName(name)
        if UserDefaults.standard.bool(forKey: "showDesktopWidget") || CommandLine.arguments.contains("--snapshot") {
            window.orderFront(nil)
        }
    }

    /// Debug: `TokenMeter --snapshot out.png [today|week|month|dayN] [--popover]` renders the widget to a PNG and quits.
    func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let mode = i + 2 < args.count ? args[i + 2] : "today"
        if mode.hasPrefix("day"), let n = Int(mode.dropFirst(3)) { store.pickedDay = daysAgo(n) }
        else { store.preset = mode == "week" ? .week : mode == "month" ? .month : .today }
        if let t = args.first(where: { $0.hasPrefix("provider=") }) { store.provider = String(t.dropFirst(9)) }
        if let m = args.first(where: { $0.hasPrefix("model=") }) { store.model = String(m.dropFirst(6)) }
        if let m = args.first(where: { $0.hasPrefix("mode=") }) { store.mode = String(m.dropFirst(5)) }
        window.contentView?.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        if args.contains("--popover"), let blur = window.contentView {
            hosting.removeFromSuperview()
            hosting = ClickThroughHostingView(rootView: WidgetView(store: store, menu: menu, inPopover: true))
            hosting.frame = blur.bounds
            hosting.autoresizingMask = [.width, .height]
            blur.addSubview(hosting)
            fit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            let t = r.total(from: today(), to: today()).cost
            let m = r.total(from: daysAgo(29), to: today()).cost
            menu.addItem(withTitle: "Today \(usd(t)) · 30 days \(usd(m))", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        add(menu, "Refresh", #selector(refresh), "r")
        add(menu, "Show on Desktop", #selector(toggleWidget), "", on: window.isVisible)
        add(menu, "Launch at Login", #selector(toggleLogin), "", on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add(menu, "Quit TokenMeter", #selector(NSApplication.terminate(_:)), "q")
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String, on: Bool = false) {
        let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        item.target = sel == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.state = on ? .on : .off
    }

    @objc func refresh() { store.refresh() }

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

    @objc func toggleWidget() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFront(nil) }
        UserDefaults.standard.set(window.isVisible, forKey: "showDesktopWidget")
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change login item"
            a.informativeText = "\(error.localizedDescription)\nMove TokenMeter.app to /Applications and try again."
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
