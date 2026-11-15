// TokenMeter.app: menu bar panel (and optional desktop widget) showing local token usage and
// API-equivalent cost for Claude Code and Codex CLI. Reads local logs only.
import AppKit
import Combine
import Charts
import ServiceManagement
import SwiftUI

let chartDays = 30
let scanDays = 60 // twice the longest range, for the "vs previous period" delta
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
    var onUpdate: ((Report) -> Void)?
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let r = Scanner.run()
            DispatchQueue.main.async { self.report = r; self.onUpdate?(r) }
        }
    }
}

// MARK: - Widget UI

enum Preset: String, CaseIterable, Identifiable {
    case today = "Today", week = "7D", month = "30D"
    var id: String { rawValue }
    var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
    var title: String { self == .today ? "Today" : self == .week ? "Last 7 days" : "Last 30 days" }
}

struct WidgetView: View {
    @ObservedObject var store: Store
    let menu: NSMenu
    var inPopover = false

    var pickedDay: Date? { store.pickedDay }
    var provider: String? { store.provider }

    /// Selected range: a clicked day, or the preset ending today.
    var range: (from: Date, to: Date, days: Int, title: String) {
        if let d = pickedDay { return (d, d, 1, d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) }
        return (daysAgo(store.preset.days - 1), today(), store.preset.days, store.preset.title)
    }

    /// Entries in [from, to] for the selected provider/model (all when nil).
    func scoped(_ r: Report, _ from: Date, _ to: Date) -> [Entry] {
        r.entries(from: from, to: to).filter { (provider == nil || $0.provider == provider) && (store.model == nil || $0.model == store.model) }
    }
    func sum(_ es: [Entry]) -> Row { es.reduce(into: Row()) { $0.add($1.row) } }
    /// Providers that have any usage in the scan window, in fixed order.
    var present: [(name: String, color: Color)] {
        let seen = Set(store.report?.entries.map { $0.provider } ?? [])
        return providers.filter { seen.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            providerChips
            if let r = store.report {
                hero(r)
                chart(r)
                stats(r)
                breakdown(r)
                if !r.unpriced.isEmpty {
                    Label("No price for \(r.unpriced.sorted().joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundColor(.orange)
                }
            } else {
                Text("Scanning logs…").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(18)
        .frame(width: 360)
    }

    var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").foregroundColor(provider.map(providerColor) ?? .accentColor)
                Text("TokenMeter").font(.system(size: 13, weight: .semibold))
            }
            .contentShape(Rectangle())
            .overlay(inPopover ? nil : DragHandle(menu: menu)) // desktop: drag to move, right-click for menu
            Spacer()
            Picker("", selection: Binding(get: { store.preset }, set: { store.preset = $0; store.pickedDay = nil })) {
                ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
            .opacity(pickedDay == nil ? 1 : 0.45) // a clicked day overrides the preset
        }
    }

    var providerChips: some View {
        HStack(spacing: 6) {
            chip("All", nil, .primary)
            ForEach(present, id: \.name) { chip($0.name, $0.name, $0.color) }
            Spacer()
        }
    }

    func chip(_ label: String, _ value: String?, _ color: Color) -> some View {
        let on = store.provider == value
        return Button { store.provider = value; store.model = nil } label: {
            HStack(spacing: 5) {
                if value != nil { Circle().fill(color).frame(width: 6, height: 6) }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(on ? color.opacity(value == nil ? 0.15 : 0.22) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? color.opacity(0.55) : Color.clear, lineWidth: 1))
            .foregroundColor(on ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    func hero(_ r: Report) -> some View {
        let g = range
        let cur = sum(scoped(r, g.from, g.to))
        let prevFrom = cal.date(byAdding: .day, value: -g.days, to: g.from)!
        let prev = sum(scoped(r, prevFrom, cal.date(byAdding: .day, value: -1, to: g.from)!))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundColor(.secondary)
                Spacer()
                if pickedDay != nil {
                    Button("Back to \(store.preset.title)") { store.pickedDay = nil }
                        .buttonStyle(.link).font(.caption2)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(usd(cur.cost)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                if prev.cost > 0.005 {
                    let pct = (cur.cost - prev.cost) / prev.cost * 100
                    let c: Color = pct >= 0 ? .orange : .green
                    Text(String(format: "%@ %.0f%%", pct >= 0 ? "▲" : "▼", abs(pct)))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(c.opacity(0.18))).foregroundColor(c)
                        .help("vs previous \(g.days == 1 ? "day" : "\(g.days) days")")
                }
            }
            Text("\(tok(cur.tokens)) tokens · \(Int(cur.calls)) calls")
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
        }
    }

    func chart(_ r: Report) -> some View {
        let from = daysAgo(chartDays - 1)
        let data = scoped(r, from, today())
        let g = range
        let avg = g.days > 1 ? sum(scoped(r, g.from, g.to)).cost / Double(g.days) : 0
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { _, e in
                BarMark(x: .value("Day", e.day, unit: .day), y: .value("Cost", e.row.cost))
                    .foregroundStyle(by: .value("Provider", e.provider))
                    .cornerRadius(2.5)
                    .opacity(e.day >= g.from && e.day <= g.to ? 1 : 0.3)
            }
            if avg > 0 {
                RuleMark(y: .value("Avg", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartForegroundStyleScale(domain: providers.map { $0.name }, range: providers.map { $0.color })
        .chartXScale(domain: from ... cal.date(byAdding: .day, value: 1, to: today())!)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : "$\(Int(d))") } }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                        if let d: Date = proxy.value(atX: x) {
                            let day = cal.startOfDay(for: d)
                            store.pickedDay = (pickedDay == day || day > today()) ? nil : day
                        }
                    }
            }
        }
        .frame(height: 96)
        .font(.system(size: 9))
    }

    func stats(_ r: Report) -> some View {
        let g = range
        let es = scoped(r, g.from, g.to)
        let cur = sum(es)
        let daily = Dictionary(grouping: es, by: { $0.day }).mapValues { $0.reduce(0) { $0 + $1.row.cost } }
        let peak = daily.max { $0.value < $1.value }
        let inputSide = cur.input + cur.cacheRead + cur.cacheWrite
        return HStack(spacing: 6) {
            tile("Avg / day", usd(cur.cost / Double(g.days)))
            tile("Peak day", peak.map { usd($0.value) } ?? "—", peak.map { dayLabel($0.key) })
            tile("Cache hit", inputSide > 0 ? String(format: "%.0f%%", cur.cacheRead / inputSide * 100) : "—")
            tile("Cache saved", usd(cur.saved))
        }
    }

    func tile(_ label: String, _ value: String, _ sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub ?? " ").font(.system(size: 9)).foregroundColor(.secondary) // keeps tiles equal height
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    func breakdown(_ r: Report) -> some View {
        let g = range
        let es = scoped(r, g.from, g.to)
        let cur = sum(es)
        typealias Item = (name: String, color: Color, value: Double, right: String, select: () -> Void)
        let items: [Item]
        let title: String
        if store.model != nil {
            // One model: what its tokens are made of.
            title = "TOKEN MIX"
            let c = providerColor(es.first?.provider ?? provider ?? "")
            items = [("Input", cur.input), ("Output", cur.output), ("Cache read", cur.cacheRead), ("Cache write", cur.cacheWrite)]
                .map { p in (p.0, c, cur.tokens > 0 ? p.1 / cur.tokens : 0, tok(p.1), {}) }
        } else if let p = provider {
            title = "BY MODEL"
            items = Dictionary(grouping: es, by: { $0.model }).map { kv in
                let row = sum(kv.value)
                return (kv.key, providerColor(p), cur.cost > 0 ? row.cost / cur.cost : 0,
                        r.unpriced.contains(kv.key) ? "—" : usd(row.cost), { store.model = kv.key })
            }.sorted { $0.value > $1.value }
        } else {
            title = "BY PROVIDER"
            items = present.map { p in
                let row = sum(es.filter { $0.provider == p.name })
                return (p.name, p.color, cur.cost > 0 ? row.cost / cur.cost : 0, usd(row.cost), { store.provider = p.name })
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundColor(.secondary)
                Spacer()
                modelPicker(r)
            }
            if es.isEmpty {
                Text("No usage in this period").font(.caption).foregroundColor(.secondary)
            }
            ForEach(items, id: \.name) { item in
                Button(action: item.select) {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            if title == "BY PROVIDER" { Circle().fill(item.color).frame(width: 7, height: 7) }
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", item.value * 100))
                                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                            Text(item.right)
                                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                .frame(minWidth: 58, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(item.color).frame(width: max(0, geo.size.width * item.value))
                            }
                        }
                        .frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
                Section(g.0) {
                    ForEach(g.1, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
    }

    var footer: some View {
        HStack(spacing: 4) {
            if let r = store.report {
                Text("Updated \(r.updated.formatted(date: .omitted, time: .shortened)) · local logs only")
            }
            Spacer()
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
