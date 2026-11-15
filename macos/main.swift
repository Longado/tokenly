// TokenMeter.app: desktop widget + menu bar item showing local token usage and
// API-equivalent cost for Claude Code and Codex CLI. Reads local logs only.
import AppKit
import ServiceManagement
import SwiftUI

let lookbackDays = 30
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

// MARK: - Scanning

struct Row {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0
    var tokens: Double { input + output + cacheRead + cacheWrite }
    mutating func add(_ r: Row) {
        input += r.input; output += r.output; cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite; cost += r.cost
    }
}

struct Report {
    var today = Row(), total = Row()
    var models: [(name: String, row: Row)] = []
    var unpriced: Set<String> = []
    var updated = Date()
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

final class Scanner {
    let since = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
    var byModel: [String: Row] = [:]
    var report = Report()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    func add(_ ts: Any?, _ model: String, _ i: Double, _ o: Double, _ cr: Double, _ cw: Double, _ cw1h: Double = 0) {
        guard let s = ts as? String, let date = isoFrac.date(from: s) ?? iso.date(from: s), date >= since else { return }
        if i + o + cr + cw == 0 { return }
        var p = prices[model] ?? [0, 0, 0, 0, 0]
        if prices[model] == nil { report.unpriced.insert(model); p = [0, 0, 0, 0, 0] }
        let cost = (i * p[0] + o * p[1] + cr * p[2] + (cw - cw1h) * p[3] + cw1h * p[4]) / 1e6
        let r = Row(input: i, output: o, cacheRead: cr, cacheWrite: cw, cost: cost)
        byModel[model, default: Row()].add(r)
        report.total.add(r)
        if Calendar.current.isDateInToday(date) { report.today.add(r) }
    }

    /// Lines of every .jsonl under `dir` modified within the lookback window.
    func lines(under dir: String) -> [[Substring]] {
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
        for file in lines(under: root + "/projects") {
            for line in file where line.contains("\"usage\"") {
                guard let d = json(line), let m = d["message"] as? [String: Any],
                      let u = m["usage"] as? [String: Any] else { continue }
                // the same message can be logged several times
                if !seen.insert("\(m["id"] ?? "")|\(d["requestId"] ?? "")").inserted { continue }
                let cc = u["cache_creation"] as? [String: Any]
                add(d["timestamp"], m["model"] as? String ?? "?",
                    num(u["input_tokens"]), num(u["output_tokens"]),
                    num(u["cache_read_input_tokens"]), num(u["cache_creation_input_tokens"]),
                    num(cc?["ephemeral_1h_input_tokens"]))
            }
        }
    }

    func scanCodex(_ root: String) {
        for file in lines(under: root + "/sessions") {
            var model = "?"
            for line in file where line.contains("turn_context") || line.contains("token_count") {
                guard let d = json(line), let p = d["payload"] as? [String: Any] else { continue }
                if d["type"] as? String == "turn_context", let m = p["model"] as? String {
                    model = m
                } else if p["type"] as? String == "token_count",
                          let u = (p["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] {
                    // input includes cached tokens
                    let c = num(u["cached_input_tokens"])
                    add(d["timestamp"], model, num(u["input_tokens"]) - c, num(u["output_tokens"]),
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
        s.report.models = s.byModel.map { ($0.key, $0.value) }.sorted { $0.row.cost > $1.row.cost }
        return s.report
    }
}

// MARK: - Formatting

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
func tok(_ v: Double) -> String {
    v >= 1e9 ? String(format: "%.1fB", v / 1e9) : v >= 1e6 ? String(format: "%.1fM", v / 1e6) : String(format: "%.0fK", v / 1e3)
}

// MARK: - UI

final class Store: ObservableObject {
    @Published var report: Report?
    var onUpdate: ((Report) -> Void)?
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let r = Scanner.run()
            DispatchQueue.main.async { self.report = r; self.onUpdate?(r) }
        }
    }
}

struct WidgetView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TokenMeter")
                Spacer()
                if let r = store.report { Text(r.updated, style: .time) }
            }
            .font(.caption).foregroundColor(.secondary)
            if let r = store.report {
                HStack(spacing: 28) {
                    stat(usd(r.today.cost), "today")
                    stat(usd(r.total.cost), "last \(lookbackDays) days")
                }
                if r.models.isEmpty {
                    Text("No usage found").font(.caption).foregroundColor(.secondary)
                }
                ForEach(r.models, id: \.name) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.name).lineLimit(1)
                            Spacer()
                            Text("\(tok(m.row.tokens)) · \(r.unpriced.contains(m.name) ? "no price" : usd(m.row.cost))")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        ProgressView(value: r.total.cost > 0 ? m.row.cost / r.total.cost : 0)
                            .progressViewStyle(.linear)
                    }
                }
            } else {
                Text("Scanning…").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

/// Transparent overlay: drag anywhere to move the widget, right-click for the menu.
final class DragView: NSView {
    var contextMenu: NSMenu?
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var window: NSWindow!
    var hosting: NSHostingView<WidgetView>!
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TM"
        menu.delegate = self
        statusItem.menu = menu
        store.onUpdate = { [weak self] r in
            self?.statusItem.button?.title = usd(r.today.cost)
            self?.fitWindow()
        }
        store.refresh()
        Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in self?.store.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.store.refresh() }
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
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

        hosting = NSHostingView(rootView: WidgetView(store: store))
        let drag = DragView()
        drag.contextMenu = menu
        for v in [hosting!, drag] as [NSView] {
            v.frame = blur.bounds
            v.autoresizingMask = [.width, .height]
            blur.addSubview(v)
        }

        let name = "TokenMeterWidget"
        if !window.setFrameUsingName(name), let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 340, y: screen.maxY - 40))
        }
        window.setFrameAutosaveName(name)
        if !UserDefaults.standard.bool(forKey: "hidden") { window.orderFront(nil) }
    }

    func fitWindow() {
        DispatchQueue.main.async {
            let size = self.hosting.fittingSize
            let f = self.window.frame
            self.window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height),
                                 display: true)
        }
    }

    // Rebuilt every time it opens so the summary and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let r = store.report {
            menu.addItem(withTitle: "Today \(usd(r.today.cost)) · \(lookbackDays)d \(usd(r.total.cost))", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        add(menu, "Refresh", #selector(refresh), "r")
        add(menu, "Show Widget", #selector(toggleWidget), "", on: window.isVisible)
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

    @objc func toggleWidget() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFront(nil) }
        UserDefaults.standard.set(!window.isVisible, forKey: "hidden")
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
