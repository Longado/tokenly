// TokenMeter.app: desktop widget + menu bar item showing local token usage and
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

let tools: [(name: String, color: Color)] = [
    ("Claude Code", Color(red: 0.85, green: 0.47, blue: 0.34)),
    ("Codex", Color(red: 0.40, green: 0.62, blue: 1.0)),
]
func toolColor(_ t: String) -> Color { tools.first { $0.name == t }?.color ?? .gray }

// MARK: - Data

struct Row {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0, saved = 0.0
    var tokens: Double { input + output + cacheRead + cacheWrite }
    mutating func add(_ r: Row) {
        input += r.input; output += r.output; cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite; cost += r.cost; saved += r.saved
    }
}

/// Usage of one model on one tool on one local day.
struct Entry {
    let day: Date, tool: String, model: String
    var row: Row
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
        let r = Row(input: i, output: o, cacheRead: cr, cacheWrite: cw, cost: cost, saved: cr * (p[0] - p[2]) / 1e6)
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
    case today = "Today", week = "7 Days", month = "30 Days"
    var id: String { rawValue }
    var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
}

struct WidgetView: View {
    @ObservedObject var store: Store
    let menu: NSMenu
    var inPopover = false
    var preset: Preset { store.preset }
    var pickedDay: Date? { store.pickedDay }

    /// Selected range: a clicked day, or the preset ending today.
    var range: (from: Date, to: Date, days: Int, title: String) {
        if let d = pickedDay { return (d, d, 1, dayLabel(d)) }
        return (daysAgo(preset.days - 1), today(), preset.days, preset.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let r = store.report {
                Picker("", selection: Binding(get: { preset }, set: { store.preset = $0; store.pickedDay = nil })) {
                    ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .opacity(pickedDay == nil ? 1 : 0.45) // a clicked day overrides the preset
                summary(r)
                chart(r)
                breakdown(r)
                if !r.unpriced.isEmpty {
                    Text("No price for: \(r.unpriced.sorted().joined(separator: ", "))")
                        .font(.caption2).foregroundColor(.orange)
                }
            } else {
                Text("Scanning…").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    var header: some View {
        HStack {
            Text("TokenMeter").fontWeight(.semibold)
            Spacer()
            if let r = store.report {
                Text("Updated \(r.updated.formatted(date: .omitted, time: .shortened))")
                    .padding(.trailing, inPopover ? 44 : 0)
            }
        }
        .font(.caption).foregroundColor(.secondary)
        .contentShape(Rectangle())
        .overlay(inPopover ? nil : DragHandle(menu: menu)) // drag to move, right-click for menu
        .overlay(alignment: .trailing) {
            if inPopover {
                HStack(spacing: 2) {
                    Spacer()
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    Button { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .buttonStyle(.borderless)
                .background(Color.clear)
            }
        }
    }

    func summary(_ r: Report) -> some View {
        let g = range
        let cur = r.total(from: g.from, to: g.to)
        let prevTo = cal.date(byAdding: .day, value: -g.days, to: g.to)!
        let prev = r.total(from: cal.date(byAdding: .day, value: -g.days, to: g.from)!, to: prevTo)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(usd(cur.cost)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(g.title).font(.caption).foregroundColor(.secondary)
                Spacer()
                if pickedDay != nil {
                    Button("Clear") { store.pickedDay = nil }.buttonStyle(.link).font(.caption)
                }
            }
            HStack(spacing: 10) {
                Text("\(tok(cur.tokens)) tokens")
                if prev.cost > 0 {
                    let pct = (cur.cost - prev.cost) / prev.cost * 100
                    Text(String(format: "%@ %.0f%% vs prev", pct >= 0 ? "▲" : "▼", abs(pct)))
                        .foregroundColor(pct >= 0 ? .orange : .green)
                }
                if cur.saved > 0 { Text("cache saved \(usd(cur.saved))") }
            }
            .font(.caption).foregroundColor(.secondary)
        }
    }

    func chart(_ r: Report) -> some View {
        let from = daysAgo(chartDays - 1)
        let data = r.entries(from: from, to: today())
        let g = range
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { _, e in
                BarMark(x: .value("Day", e.day, unit: .day), y: .value("Cost", e.row.cost))
                    .foregroundStyle(by: .value("Tool", e.tool))
                    .opacity(e.day >= g.from && e.day <= g.to ? 1 : 0.35)
            }
        }
        .chartForegroundStyleScale(domain: tools.map { $0.name }, range: tools.map { $0.color })
        .chartXScale(domain: from ... cal.date(byAdding: .day, value: 1, to: today())!)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(usd(d)) } }
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
        .frame(height: 90)
        .font(.caption2)
    }

    func breakdown(_ r: Report) -> some View {
        let g = range
        let es = r.entries(from: g.from, to: g.to)
        let total = es.reduce(0) { $0 + $1.row.cost }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(tools, id: \.name) { t in
                let te = es.filter { $0.tool == t.name }
                let row = te.reduce(into: Row()) { $0.add($1.row) }
                let models = Dictionary(grouping: te, by: { $0.model })
                    .map { ($0.key, $0.value.reduce(into: Row()) { $0.add($1.row) }) }
                    .sorted { $0.1.cost > $1.1.cost }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(t.color).frame(width: 8, height: 8)
                        Text(t.name).fontWeight(.medium)
                        Spacer()
                        Text(tok(row.tokens)).foregroundColor(.secondary)
                        Text(usd(row.cost)).frame(minWidth: 56, alignment: .trailing)
                    }
                    .font(.callout)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(t.color)
                                .frame(width: geo.size.width * (total > 0 ? row.cost / total : 0))
                        }
                    }
                    .frame(height: 4)
                    ForEach(models, id: \.0) { m in
                        HStack {
                            Text(m.0).lineLimit(1)
                            Spacer()
                            Text(tok(m.1.tokens))
                            Text(r.unpriced.contains(m.0) ? "—" : usd(m.1.cost)).frame(minWidth: 56, alignment: .trailing)
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.leading, 16)
                    }
                    if te.isEmpty {
                        Text("No usage").font(.caption).foregroundColor(.secondary).padding(.leading, 16)
                    }
                }
            }
        }
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
