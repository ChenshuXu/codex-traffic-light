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

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
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

    var aggregate: LightState? {
        Self.aggregate(for: tasks, errorMessage: errorMessage)
    }

    static func aggregate(for tasks: [CodexTask], errorMessage: String?) -> LightState? {
        guard errorMessage == nil else { return nil }
        return tasks.map(\.state).max()
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
                    if self.tasks != snapshot.tasks { self.tasks = snapshot.tasks }
                    if self.errorMessage != nil { self.errorMessage = nil }
                case .failure(let error):
                    let message = error.localizedDescription
                    if self.errorMessage != message { self.errorMessage = message }
                }
            }
        }
    }
}

final class AppSettings: ObservableObject {
    private enum Key {
        static let showDesktopAtLaunch = "showDesktopAtLaunch"
        static let alwaysOnTop = "alwaysOnTop"
        static let showCompleted = "showCompleted"
    }

    @Published var showDesktopAtLaunch: Bool {
        didSet { defaults.set(showDesktopAtLaunch, forKey: Key.showDesktopAtLaunch) }
    }
    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }
    @Published var showCompleted: Bool {
        didSet { defaults.set(showCompleted, forKey: Key.showCompleted) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDesktopAtLaunch = defaults.object(forKey: Key.showDesktopAtLaunch) as? Bool ?? true
        alwaysOnTop = defaults.object(forKey: Key.alwaysOnTop) as? Bool ?? true
        showCompleted = defaults.object(forKey: Key.showCompleted) as? Bool ?? true
    }
}

struct TrafficLightIcon: View {
    let state: LightState?

    var body: some View {
        Circle()
            .fill(state?.color ?? Color.secondary.opacity(0.55))
            .frame(width: 11, height: 11)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex，\(state?.label ?? "暂无状态")")
    }
}

enum MenuBarDot {
    static func image(for state: LightState?) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let diameter: CGFloat = 9
            let x = (size.width - diameter) / 2
            let y = (size.height - diameter) / 2
            (state?.nsColor ?? .systemGray).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
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
    @ObservedObject var settings: AppSettings
    let isDesktop: Bool
    let showDesktop: () -> Void
    let showSettings: () -> Void

    private var visibleTasks: [CodexTask] {
        settings.showCompleted ? monitor.tasks : monitor.tasks.filter { $0.state != .green }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                TrafficLightIcon(state: monitor.aggregate)
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
            } else if visibleTasks.isEmpty {
                Text(monitor.tasks.isEmpty ? "还没有可显示的 Codex 任务" : "没有正在运行或需要操作的任务")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                VStack(spacing: 5) {
                    ForEach(visibleTasks) { task in
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

                Group {
                    if isDesktop {
                        Button {
                            settings.alwaysOnTop.toggle()
                        } label: {
                            Label(settings.alwaysOnTop ? "取消置顶" : "置顶", systemImage: settings.alwaysOnTop ? "pin.slash" : "pin")
                        }
                        .help(settings.alwaysOnTop ? "让窗口恢复普通层级" : "让窗口固定在其他窗口前面")
                    } else {
                        Button {
                            showDesktop()
                        } label: {
                            Label("桌面窗口", systemImage: "macwindow")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button {
                    showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("设置")

                if !isDesktop {
                    Button("退出") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
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

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Traffic Light 设置")
                .font(.system(size: 16, weight: .semibold))
            Toggle("启动应用时显示桌面窗口", isOn: $settings.showDesktopAtLaunch)
            Toggle("桌面窗口始终置顶", isOn: $settings.alwaysOnTop)
            Toggle("显示已完成任务", isOn: $settings.showCompleted)
            Text("关闭桌面窗口只会把它隐藏；菜单栏圆点仍会继续更新。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .padding(18)
        .frame(width: 340)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = TaskMonitor()
    private let settings = AppSettings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var popoverHost: NSHostingController<Dashboard>?
    private var panelHost: NSHostingController<Dashboard>?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        configurePanel()
        configureSettingsWindow()

        monitor.$tasks.combineLatest(monitor.$errorMessage)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
                self?.resizeDashboards()
            }
            .store(in: &cancellables)
        settings.$showCompleted
            .sink { [weak self] _ in self?.resizeDashboards() }
            .store(in: &cancellables)
        settings.$alwaysOnTop
            .sink { [weak self] _ in self?.applyPanelLevel() }
            .store(in: &cancellables)

        updateStatusItem()
        if settings.showDesktopAtLaunch {
            DispatchQueue.main.async { [weak self] in self?.showDesktop(activate: false) }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func configurePopover() {
        let root = Dashboard(
            monitor: monitor,
            settings: settings,
            isDesktop: false,
            showDesktop: { [weak self] in
                self?.popover.performClose(nil)
                self?.showDesktop(activate: true)
            },
            showSettings: { [weak self] in self?.showSettings() }
        )
        let host = NSHostingController(rootView: root)
        popoverHost = host
        popover.behavior = .transient
        popover.contentViewController = host
    }

    private func configurePanel() {
        let root = Dashboard(
            monitor: monitor,
            settings: settings,
            isDesktop: true,
            showDesktop: {},
            showSettings: { [weak self] in self?.showSettings() }
        )
        let host = NSHostingController(rootView: root)
        panelHost = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex 状态"
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let frameName = "CodexTrafficLightDesktopWindow"
        if !panel.setFrameUsingName(frameName), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 18, y: visible.maxY - panel.frame.height - 18))
        }
        panel.setFrameAutosaveName(frameName)
        self.panel = panel
        applyPanelLevel()
    }

    private func configureSettingsWindow() {
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Traffic Light 设置"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        settingsWindow = window
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarDot.image(for: monitor.aggregate)
        let detail = monitor.errorMessage == nil ? (monitor.aggregate?.label ?? "没有任务") : "状态读取失败"
        button.setAccessibilityLabel("Codex，\(detail)")
        button.toolTip = "Codex：\(detail)"
    }

    private func resizeDashboards() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let host = self.popoverHost {
                host.view.layoutSubtreeIfNeeded()
                self.popover.contentSize = host.view.fittingSize
            }
            guard let panel = self.panel, let host = self.panelHost else { return }
            host.view.layoutSubtreeIfNeeded()
            let oldTop = panel.frame.maxY
            panel.setContentSize(host.view.fittingSize)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - panel.frame.height))
        }
    }

    private func applyPanelLevel() {
        panel?.isFloatingPanel = settings.alwaysOnTop
        panel?.level = settings.alwaysOnTop ? .floating : .normal
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        resizeDashboards()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showDesktop(activate: Bool) {
        guard let panel else { return }
        resizeDashboards()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private func runSelfTest() {
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

    let now = Date()
    let green = CodexTask(id: "g", title: "green", state: .green, updatedAt: now)
    let yellow = CodexTask(id: "y", title: "yellow", state: .yellow, updatedAt: now)
    let red = CodexTask(id: "r", title: "red", state: .red, updatedAt: now)
    precondition(TaskMonitor.aggregate(for: [green, yellow, red], errorMessage: nil) == .red)
    precondition(TaskMonitor.aggregate(for: [], errorMessage: nil) == nil)
    precondition(TaskMonitor.aggregate(for: [red], errorMessage: "failed") == nil)

    let menuImage = MenuBarDot.image(for: .yellow)
    precondition(menuImage.size == NSSize(width: 18, height: 14))
    precondition((menuImage.tiffRepresentation?.count ?? 0) > 100)

    let suiteName = "com.newton.codex-traffic-light.self-test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { preconditionFailure("无法创建测试设置") }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let initial = AppSettings(defaults: defaults)
    precondition(initial.showDesktopAtLaunch && initial.alwaysOnTop && initial.showCompleted)
    initial.alwaysOnTop = false
    initial.showCompleted = false
    let restored = AppSettings(defaults: defaults)
    precondition(!restored.alwaysOnTop && !restored.showCompleted)
    print("Codex Traffic Light self-test passed")
}

private func printLiveSnapshot() -> Never {
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

if CommandLine.arguments.contains("--self-test") {
    runSelfTest()
    exit(EXIT_SUCCESS)
}
if CommandLine.arguments.contains("--check-live") {
    printLiveSnapshot()
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
