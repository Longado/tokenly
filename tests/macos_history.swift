import Foundation

func testUsageHistory() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let home = environment["CFFIXED_USER_HOME"],
          (home as NSString).resolvingSymlinksInPath == (NSHomeDirectory() as NSString).resolvingSymlinksInPath,
          environment["CODEX_HOME"] == home + "/codex",
          environment["CLAUDE_CONFIG_DIR"] == home + "/claude" else {
        fatalError("Run the test with an isolated home and tool directories")
    }
    let active = URL(fileURLWithPath: home + "/codex/sessions")
    let archive = URL(fileURLWithPath: home + "/codex/archived_sessions")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    let search = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/zstd" }
    guard let zstd = search.first(where: FileManager.default.isExecutableFile(atPath:)) else {
        fatalError("The compressed rollout fixture needs zstd")
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter()
    func rollout(at date: Date, model: String, reset: Date? = nil) throws -> Data {
        var payload: [String: Any] = [
            "type": "token_count", "info": ["last_token_usage": ["input_tokens": 100]],
        ]
        if let reset {
            payload["rate_limits"] = ["secondary": [
                "window_minutes": 10080, "used_percent": 42, "resets_at": reset.timeIntervalSince1970,
            ]]
        }
        let context = try JSONSerialization.data(withJSONObject: ["type": "turn_context", "payload": ["model": model]])
        let usage = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "timestamp": timestamp.string(from: date), "payload": payload,
        ])
        return context + Data([10]) + usage + Data([10])
    }

    func compress(_ data: Data, to file: URL) throws {
        let source = URL(fileURLWithPath: home + "/compression-input")
        try data.write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-q", "-f", "-o", file.path, "--", source.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }

    let current = try rollout(at: now.addingTimeInterval(-60), model: "gpt-6.1-sol")
    try current.write(to: active.appendingPathComponent("rollout-current.jsonl"))
    try compress(current, to: archive.appendingPathComponent("rollout-current.jsonl.zst"))
    let previous = now.addingTimeInterval(-10 * 86400)
    try rollout(at: previous, model: "gpt-6.1-sol", reset: previous.addingTimeInterval(86400))
        .write(to: archive.appendingPathComponent("rollout-archived.jsonl"))
    let old = now.addingTimeInterval(-33 * 86400)
    let unpriced = try rollout(at: old, model: "fixture-without-price", reset: old.addingTimeInterval(2 * 86400))
    try compress(Data(unpriced.dropLast()), to: active.appendingPathComponent("rollout-older.jsonl.zst"))
    try Data("invalid zstd".utf8).write(to: archive.appendingPathComponent("rollout-broken.jsonl.zst"))

    let scanner = Scanner()
    scanner.liveClaude = false
    scanner.liveCodex = false
    var beforeBackfill: [Report] = []
    let report = scanner.run { beforeBackfill.append($0) }
    func tokens(_ report: Report) -> Double { report.entries.reduce(0) { $0 + $1.row.tokens } }
    precondition(beforeBackfill.count == 1 && beforeBackfill[0].loadingCodexHistory && tokens(beforeBackfill[0]) == 200)
    precondition(!report.loadingCodexHistory && tokens(report) == 300)
    precondition(tokens(scanner.run()) == 300)
    precondition(report.quotas.isEmpty && report.codexHistoryStatus == "Some Codex logs could not be read")
    let weeks = planWeeks(report, "Codex")
    precondition(weeks.contains { ($0.cost ?? 0) > 0 })
    precondition(weeks.contains { $0.hasUnpricedUsage && $0.cost == 0 })
    precondition(historyCost(nil, partial: false) == "—" && historyCost(0, partial: true) == "—")
    precondition(historyCost(2, partial: true) == "≥ $2.00")
    print("Usage history tests passed.")
}
