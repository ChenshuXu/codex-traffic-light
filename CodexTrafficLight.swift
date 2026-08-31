import AppKit
import Combine
import Darwin
import SQLite3
import SwiftUI

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum LightState: Int, Comparable {
    case green = 0
    case yellow = 1
    case red = 2

    static func < (lhs: LightState, rhs: LightState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        }
    }

    var label: String {
        switch self {
        case .red: "需要操作"
        case .yellow: "运行中"
        case .green: "已完成"
        }
    }
}

struct CodexTask: Identifiable, Equatable {
    let id: String
    let title: String
    let state: LightState
    let updatedAt: Date
}

struct Snapshot {
    let tasks: [CodexTask]
}

enum StatusReader {
    enum Lifecycle {
        case started
        case completed
    }

    struct RolloutSignals {
        var lifecycle: Lifecycle?
        var pendingQuestion = false
    }

    private static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    private static var signalCache: [String: (size: UInt64, signals: RolloutSignals)] = [:]

    static func load() throws -> Snapshot {
        let stateURL = try latestDatabase(prefix: "state")
        let lockIDs = try writerLockIDs()
        var database: OpaquePointer?

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let openResult = sqlite3_open_v2(readOnlyURI(stateURL), &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            let error = failure(database, "无法打开 Codex 状态数据库")
            if let database { sqlite3_close(database) }
            throw error
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        let sql = """
        WITH recent AS (
          SELECT id,
                 COALESCE(NULLIF(name, ''), '未命名任务') AS display_title,
                 rollout_path,
                 CASE
                   WHEN recency_at_ms > 0 THEN recency_at_ms
                   WHEN updated_at_ms > 0 THEN updated_at_ms
                   ELSE updated_at * 1000
                 END AS recency_ms
          FROM threads
          WHERE archived = 0
            AND (thread_source IS NULL OR thread_source = '' OR thread_source IN ('user', 'automation'))
            AND source IN ('vscode', 'cli', 'exec', 'appServer')
          ORDER BY recency_ms DESC
        )
        SELECT id, display_title, rollout_path, recency_ms
        FROM recent
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw failure(database, "无法查询 Codex 任务")
        }
        defer { sqlite3_finalize(statement) }

        var tasks: [CodexTask] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let id = text(statement, 0)
            let title = cleanTitle(text(statement, 1))
            let rolloutPath = text(statement, 2)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1_000)
            let lockHeld = lockIDs.contains(id) ? try hasLiveWriter(threadID: id) : false
            let signals = lockHeld ? readSignals(rolloutPath: rolloutPath) : RolloutSignals()
            let state = classify(lockHeld: lockHeld, signals: signals)
            tasks.append(CodexTask(id: id, title: title, state: state, updatedAt: updatedAt))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw failure(database, "读取 Codex 任务时发生错误")
        }

        tasks.sort {
            if $0.state != $1.state { return $0.state > $1.state }
            return $0.updatedAt > $1.updatedAt
        }
        return Snapshot(tasks: Array(tasks.prefix(8)))
    }

    static func classify(
        lockHeld: Bool,
        signals: RolloutSignals
    ) -> LightState {
        guard lockHeld, signals.lifecycle != .completed else { return .green }
        return signals.pendingQuestion ? .red : .yellow
    }

    static func signals(in data: Data) -> RolloutSignals {
        var result = RolloutSignals()
        var pending = Set<String>()
        for rawLine in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let recordType = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if recordType == "event_msg", let event = payload["type"] as? String {
                if event == "task_started" {
                    pending.removeAll()
                    result.lifecycle = .started
                }
                if event == "task_complete" {
                    pending.removeAll()
                    result.lifecycle = .completed
                }
                continue
            }

            guard recordType == "response_item",
                  let kind = payload["type"] as? String,
                  let callID = payload["call_id"] as? String else { continue }
            if kind == "function_call", payload["name"] as? String == "request_user_input" {
                pending.insert(callID)
            } else if kind == "function_call_output" {
                pending.remove(callID)
            }
        }
        result.pendingQuestion = !pending.isEmpty
        return result
    }

    private static func readSignals(rolloutPath: String) -> RolloutSignals {
        let url = URL(fileURLWithPath: rolloutPath).standardizedFileURL
        guard url.path.hasPrefix(codexDirectory.standardizedFileURL.path + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return RolloutSignals()
        }
        defer { try? handle.close() }

        let byteCount = size.uint64Value
        if let cached = signalCache[url.path], cached.size == byteCount {
            return cached.signals
        }

        guard let end = try? handle.seekToEnd() else { return RolloutSignals() }
        // ponytail: completion is the final small record and a waiting prompt stops the
        // turn, so a 256 KiB tail is enough; use an
        // app-server proxy only if protocol-perfect approval tracking becomes necessary.
        let start = end > 262_144 ? end - 262_144 : 0
        do {
            try handle.seek(toOffset: start)
            let result = signals(in: try handle.readToEnd() ?? Data())
            signalCache[url.path] = (byteCount, result)
            return result
        } catch {
            return RolloutSignals()
        }
    }

    private static func hasLiveWriter(threadID: String) throws -> Bool {
        let lockURL = codexDirectory
            .appendingPathComponent("thread-writer-locks", isDirectory: true)
            .appendingPathComponent("\(threadID).lock")
        let descriptor = Darwin.open(lockURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw ReaderError("无法读取 Codex writer lock")
        }
        defer { Darwin.close(descriptor) }

        if systemFlock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = systemFlock(descriptor, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN { return true }
        throw ReaderError("无法检查 Codex writer lock")
    }

    private static func writerLockIDs() throws -> Set<String> {
        let directory = codexDirectory.appendingPathComponent("thread-writer-locks", isDirectory: true)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return Set(names.compactMap { name in
                guard name.hasSuffix(".lock") else { return nil }
                return String(name.dropLast(5))
            })
        } catch {
            throw ReaderError("无法读取 Codex writer lock 目录")
        }
    }

    private static func latestDatabase(prefix: String) throws -> URL {
        let pattern = try NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: prefix))_(\\d+)\\.sqlite$")
        let candidates = try FileManager.default.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: nil
        ).compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: range),
                  let versionRange = Range(match.range(at: 1), in: name),
                  let version = Int(name[versionRange]) else {
                return nil
            }
            return (version, url)
        }
        guard let newest = candidates.max(by: { $0.0 < $1.0 }) else {
            throw ReaderError("找不到 ~/.codex/\(prefix)_*.sqlite")
        }
        return newest.1
    }

    private static func readOnlyURI(_ url: URL) -> String {
        url.absoluteString + "?mode=ro"
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func cleanTitle(_ title: String) -> String {
        let oneLine = title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? "未命名任务" : oneLine
    }

    private static func failure(_ database: OpaquePointer?, _ fallback: String) -> ReaderError {
        guard let database, let message = sqlite3_errmsg(database) else { return ReaderError(fallback) }
        return ReaderError("\(fallback)：\(String(cString: message))")
    }
}

struct ReaderError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

final class TaskMonitor: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var errorMessage: String?

    private var timer: Timer?
    private var isLoading = false

    init() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    var aggregate: LightState {
        if errorMessage != nil { return .red }
        return tasks.map(\.state).max() ?? .green
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try StatusReader.load() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let snapshot):
                    self.tasks = snapshot.tasks
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct TrafficLightIcon: View {
    let state: LightState

    var body: some View {
        HStack(spacing: 2.5) {
            dot(.red)
            dot(.yellow)
            dot(.green)
        }
        .padding(.horizontal, 4.5)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex，\(state.label)")
    }

    private func dot(_ dotState: LightState) -> some View {
        Circle()
            .fill(dotState.color.opacity(dotState == state ? 1 : 0.18))
            .frame(width: 7, height: 7)
    }
}

struct MenuBarTrafficLightIcon: View {
    let state: LightState

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .renderingMode(.original)
            .frame(width: 18, height: 12)
            .accessibilityLabel("Codex，\(state.label)")
    }

    static func image(for state: LightState) -> NSImage {
        let size = NSSize(width: 18, height: 12)
        let image = NSImage(size: size, flipped: false) { _ in
            let states: [LightState] = [.red, .yellow, .green]
            let diameter: CGFloat = 4.5
            let gap: CGFloat = 1.5
            let startX = (size.width - diameter * 3 - gap * 2) / 2
            let y = (size.height - diameter) / 2

            for (index, dotState) in states.enumerated() {
                let color: NSColor = switch dotState {
                case .red: .systemRed
                case .yellow: .systemYellow
                case .green: .systemGreen
                }
                color.withAlphaComponent(dotState == state ? 1 : 0.32).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: startX + CGFloat(index) * (diameter + gap),
                    y: y,
                    width: diameter,
                    height: diameter
                )).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct TaskRow: View {
    let task: CodexTask

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(task.state.color)
                .frame(width: 8, height: 8)
            Text(task.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(task.state.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: TaskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                TrafficLightIcon(state: monitor.aggregate)
                    .scaleEffect(1.2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex 状态")
                        .font(.system(size: 14, weight: .semibold))
                    Text("桌面版 + VS Code")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusCounts
            }

            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if monitor.tasks.isEmpty {
                Text("还没有可显示的 Codex 任务")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                VStack(spacing: 5) {
                    ForEach(monitor.tasks) { task in
                        TaskRow(task: task)
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    monitor.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var statusCounts: some View {
        HStack(spacing: 7) {
            count(.red)
            count(.yellow)
            count(.green)
        }
        .accessibilityElement(children: .combine)
    }

    private func count(_ state: LightState) -> some View {
        HStack(spacing: 3) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text("\(monitor.tasks.count { $0.state == state })")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

@main
struct CodexTrafficLightApp: App {
    @StateObject private var monitor: TaskMonitor

    init() {
        if CommandLine.arguments.contains("--self-test") {
            Self.runSelfTest()
            exit(EXIT_SUCCESS)
        }
        if CommandLine.arguments.contains("--check-live") {
            do {
                let tasks = try StatusReader.load().tasks
                let counts = Dictionary(grouping: tasks, by: \.state).mapValues(\.count)
                print("Live snapshot passed: \(tasks.count) tasks, red=\(counts[.red, default: 0]), yellow=\(counts[.yellow, default: 0]), green=\(counts[.green, default: 0])")
                exit(EXIT_SUCCESS)
            } catch {
                fputs("Live snapshot failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        _monitor = StateObject(wrappedValue: TaskMonitor())
    }

    var body: some Scene {
        MenuBarExtra {
            Dashboard(monitor: monitor)
        } label: {
            MenuBarTrafficLightIcon(state: monitor.aggregate)
        }
        .menuBarExtraStyle(.window)
    }

    private static func runSelfTest() {
        let prompt = Data("""
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"q1"}}
        """.utf8)
        let answered = Data("""
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"q1"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"q1"}}
        """.utf8)

        let running = Data("""
        {"type":"event_msg","payload":{"type":"task_started"}}
        """.utf8)
        let completed = Data("""
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8)

        precondition(StatusReader.signals(in: prompt).pendingQuestion)
        precondition(!StatusReader.signals(in: answered).pendingQuestion)
        precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: running)) == .yellow)
        precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: prompt)) == .red)
        precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: completed)) == .green)
        precondition(StatusReader.classify(lockHeld: false, signals: StatusReader.signals(in: running)) == .green)
        let menuImage = MenuBarTrafficLightIcon.image(for: .yellow)
        precondition(menuImage.size == NSSize(width: 18, height: 12))
        precondition((menuImage.tiffRepresentation?.count ?? 0) > 100)
        print("Codex Traffic Light self-test passed")
    }
}
