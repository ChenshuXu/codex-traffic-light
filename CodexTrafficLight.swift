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
        Color(nsColor: nsColor)
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
    let isUnread: Bool
    let cwd: String
    let rolloutPath: String
    let updatedAt: Date
}

enum StatusReader {
    struct RolloutSignals {
        var completed = false
        var pendingUserAction = false
    }

    private static let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    private static var signalCache: [String: (size: UInt64, signals: RolloutSignals)] = [:]
    private static var cachedDatabase: OpaquePointer?
    private static var cachedStateURL: URL?

    static func load(unreadIDs: Set<String> = []) throws -> [CodexTask] {
        var succeeded = false
        defer { if !succeeded { closeDatabase() } }
        let stateURL = try latestStateDatabase()
        let lockIDs = try writerLockIDs()
        let database = try openDatabase(at: stateURL)

        let sql = """
        SELECT id,
               COALESCE(NULLIF(name, ''), '未命名任务') AS display_title,
               COALESCE(cwd, '') AS cwd,
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
            let cwd = text(statement, 2)
            let rolloutPath = text(statement, 3)
            let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1_000)
            let lockHeld = lockIDs.contains(id) ? try hasLiveWriter(threadID: id) : false
            let signals = lockHeld ? readSignals(rolloutPath: rolloutPath) : RolloutSignals()
            let state = classify(lockHeld: lockHeld, signals: signals)
            tasks.append(CodexTask(
                id: id,
                title: title,
                state: state,
                isUnread: state == .green && unreadIDs.contains(id),
                cwd: cwd,
                rolloutPath: rolloutPath,
                updatedAt: updatedAt
            ))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw failure(database, "读取 Codex 任务时发生错误")
        }

        tasks.sort {
            if $0.state != $1.state { return $0.state > $1.state }
            if $0.isUnread != $1.isUnread { return $0.isUnread }
            return $0.updatedAt > $1.updatedAt
        }
        let visibleTasks = Array(tasks.prefix(8))
        succeeded = true
        return visibleTasks
    }

    fileprivate static func openDatabase(at stateURL: URL) throws -> OpaquePointer {
        if cachedStateURL == stateURL, let cachedDatabase { return cachedDatabase }
        closeDatabase()

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let openResult = sqlite3_open_v2(stateURL.absoluteString + "?mode=ro", &opened, flags, nil)
        guard openResult == SQLITE_OK, let opened else {
            let error = failure(opened, "无法打开 Codex 状态数据库")
            if let opened { sqlite3_close(opened) }
            throw error
        }
        sqlite3_busy_timeout(opened, 500)
        sqlite3_exec(opened, "PRAGMA query_only = ON", nil, nil, nil)
        cachedDatabase = opened
        cachedStateURL = stateURL
        return opened
    }

    fileprivate static func closeDatabase() {
        if let cachedDatabase { sqlite3_close(cachedDatabase) }
        cachedDatabase = nil
        cachedStateURL = nil
    }

    static func classify(
        lockHeld: Bool,
        signals: RolloutSignals
    ) -> LightState {
        guard lockHeld, !signals.completed else { return .green }
        return signals.pendingUserAction ? .red : .yellow
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
                    result.completed = false
                }
                if event == "task_complete" {
                    pending.removeAll()
                    result.completed = true
                }
                continue
            }

            guard recordType == "response_item",
                  let kind = payload["type"] as? String,
                  let callID = payload["call_id"] as? String else { continue }
            if kind == "function_call" || kind == "custom_tool_call" {
                let name = payload["name"] as? String
                let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
                if name == "request_user_input"
                    || ((name == "exec" || name == "exec_command")
                        && input.contains(#""sandbox_permissions":"require_escalated""#)) {
                    pending.insert(callID)
                }
            } else if kind == "function_call_output" || kind == "custom_tool_call_output" {
                pending.remove(callID)
            }
        }
        result.pendingUserAction = !pending.isEmpty
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

    private static func latestStateDatabase() throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: nil
        ).compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite",
                  name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)) else {
                return nil
            }
            return (version, url)
        }
        guard let newest = candidates.max(by: { $0.0 < $1.0 }) else {
            throw ReaderError("找不到 ~/.codex/state_*.sqlite")
        }
        return newest.1
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

enum TaskNavigator {
    static func open(_ task: CodexTask) {
        guard isVSCode(rolloutPath: task.rolloutPath) else {
            if let url = codexThreadURL(task.id) { NSWorkspace.shared.open(url) }
            return
        }

        let openThread = {
            if let url = vscodeThreadURL(task.id) { NSWorkspace.shared.open(url) }
        }
        guard let workspaceURL = vscodeWorkspaceURL(task.cwd),
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            openThread()
            return
        }

        // ponytail: VS Code has no atomic workspace + task URL. Focus the workspace
        // first, then use the extension route; keep this fallback until one exists.
        let process = Process()
        process.executableURL = applicationURL
            .appendingPathComponent("Contents/Resources/app/bin/code")
        process.arguments = ["--folder-uri", workspaceURL.absoluteString]
        do {
            try process.run()
        } catch {
            openThread()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: openThread)
        }
    }

    static func codexThreadURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    static func vscodeThreadURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "openai.chatgpt"
        components.path = "/local/\(id)"
        return components.url
    }

    static func vscodeWorkspaceURL(_ cwd: String) -> URL? {
        guard cwd.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
    }

    static func isVSCode(sessionHeader data: Data) -> Bool {
        guard let line = data.split(separator: 0x0A, maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let originator = payload["originator"] as? String else {
            return false
        }
        return originator.lowercased().contains("vscode")
    }

    private static func isVSCode(rolloutPath: String) -> Bool {
        let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        let url = URL(fileURLWithPath: rolloutPath).standardizedFileURL
        guard url.path.hasPrefix(codexDirectory.path + "/"),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        // ponytail: session_meta is currently about 20 KiB; switch to chunked
        // newline reading if Codex grows the first record beyond 64 KiB.
        guard let data = try? handle.read(upToCount: 65_536) else { return false }
        return isVSCode(sessionHeader: data)
    }
}

struct ReaderError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum VSCodeUnreadReader {
    static func load() -> Set<String>? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(url.absoluteString + "?mode=ro", &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ItemTable WHERE key = 'openai.chatgpt'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return ids(in: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    static func ids(in data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let persisted = root["persisted-atom-state"] as? [String: Any],
              let unreadByHost = persisted["unread-thread-ids-by-host-v1"] as? [String: Any],
              let local = unreadByHost["local"] as? [String] else { return [] }
        return Set(local.filter { UUID(uuidString: $0) != nil })
    }
}

enum CodexDesktopUnreadReader {
    static func load() -> Set<String>? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ids(in: data)
    }

    static func ids(in data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let persisted = root["electron-persisted-atom-state"] as? [String: Any],
              let unreadByHost = persisted["unread-thread-ids-by-host-v1"] as? [String: Any],
              let local = unreadByHost["local"] as? [String] else { return [] }
        return Set(local.filter { UUID(uuidString: $0) != nil })
    }
}

final class UnreadStore: ObservableObject {
    private static let key = "unreadThreadIDs"

    @Published private(set) var ids: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bootstrap: () -> Set<String>? = VSCodeUnreadReader.load) {
        self.defaults = defaults
        if let saved = defaults.array(forKey: Self.key) as? [String] {
            ids = Set(saved.filter { UUID(uuidString: $0) != nil })
        } else {
            ids = bootstrap() ?? []
            persist()
        }
    }

    func set(_ threadID: String, unread: Bool) {
        guard UUID(uuidString: threadID) != nil else { return }
        var updated = ids
        let changed = unread ? updated.insert(threadID).inserted : updated.remove(threadID) != nil
        guard changed else { return }
        ids = updated
        persist()
    }

    private func persist() {
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}

enum CodexIPCProtocol {
    static let maxFrameBytes = 45 * 1_024 * 1_024

    static func frame(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object)
        guard payload.count <= maxFrameBytes else { throw ReaderError("Codex IPC 消息过大") }
        let length = UInt32(payload.count)
        var data = Data([
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 24) & 0xff)
        ])
        data.append(payload)
        return data
    }

    static func nextObject(from buffer: inout Data) throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer[buffer.startIndex])
            | Int(buffer[buffer.startIndex + 1]) << 8
            | Int(buffer[buffer.startIndex + 2]) << 16
            | Int(buffer[buffer.startIndex + 3]) << 24
        guard length > 0, length <= maxFrameBytes else { throw ReaderError("Codex IPC 帧无效") }
        guard buffer.count >= length + 4 else { return nil }
        let payload = buffer.subdata(in: 4..<(length + 4))
        buffer.removeSubrange(0..<(length + 4))
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ReaderError("Codex IPC JSON 无效")
        }
        return object
    }

    static func unreadChange(in object: [String: Any]) -> (threadID: String, unread: Bool)? {
        guard object["type"] as? String == "broadcast",
              object["method"] as? String == "thread-read-state-changed",
              (object["version"] as? NSNumber)?.intValue == 2,
              let params = object["params"] as? [String: Any],
              params["hostId"] as? String == "local",
              let threadID = params["conversationId"] as? String,
              UUID(uuidString: threadID) != nil,
              let unread = params["hasUnreadTurn"] as? Bool else { return nil }
        return (threadID, unread)
    }
}

final class CodexIPCUnreadListener {
    private let queue = DispatchQueue(label: "com.newton.codex-traffic-light.ipc")
    private let socketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/ipc/ipc.sock")
    private let onChange: (String, Bool) -> Void
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private var reconnectWorkItem: DispatchWorkItem?
    private var stopped = false

    init(onChange: @escaping (String, Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.source == nil else { return }
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.reconnectWorkItem?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    private func connect() {
        guard !stopped, Self.isTrustedSocket(socketURL.path) else {
            scheduleReconnect()
            return
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            scheduleReconnect()
            return
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString.map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            scheduleReconnect()
            return
        }

        reconnectWorkItem?.cancel()
        buffer.removeAll(keepingCapacity: true)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.read(from: descriptor) }
        readSource.setCancelHandler { Darwin.close(descriptor) }
        source = readSource
        readSource.resume()

        send([
            "type": "request",
            "requestId": UUID().uuidString,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "traffic-light"]
        ], to: descriptor)
    }

    private func read(from descriptor: Int32) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else {
            if count < 0, errno == EINTR { return }
            disconnect()
            return
        }
        buffer.append(contentsOf: bytes.prefix(count))

        do {
            while let object = try CodexIPCProtocol.nextObject(from: &buffer) {
                if let change = CodexIPCProtocol.unreadChange(in: object) {
                    onChange(change.threadID, change.unread)
                } else if object["type"] as? String == "client-discovery-request",
                          let requestID = object["requestId"] as? String {
                    send([
                        "type": "client-discovery-response",
                        "requestId": requestID,
                        "response": ["canHandle": false]
                    ], to: descriptor)
                }
            }
        } catch {
            disconnect()
        }
    }

    private func send(_ object: [String: Any], to descriptor: Int32) {
        guard let frame = try? CodexIPCProtocol.frame(object) else { return }
        let written = frame.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !written { disconnect() }
    }

    private func disconnect() {
        source?.cancel()
        source = nil
        buffer.removeAll(keepingCapacity: true)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectWorkItem == nil || reconnectWorkItem?.isCancelled == true else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private static func isTrustedSocket(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_uid == getuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }
}

final class TaskMonitor: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var errorMessage: String?

    private var timer: Timer?
    private var isLoading = false
    private var consecutiveFailures = 0
    private var unreadCancellable: AnyCancellable?
    private let unreadStore: UnreadStore

    init(unreadStore: UnreadStore) {
        self.unreadStore = unreadStore
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        unreadCancellable = unreadStore.$ids.dropFirst().sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    var aggregate: LightState? {
        Self.aggregate(for: tasks, errorMessage: errorMessage)
    }

    var unreadCount: Int {
        tasks.count { $0.isUnread }
    }

    static func aggregate(for tasks: [CodexTask], errorMessage: String?) -> LightState? {
        guard errorMessage == nil else { return nil }
        return tasks.map(\.state).max()
    }

    fileprivate static func shouldPublishError(after failures: Int) -> Bool {
        failures >= 2
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let storedUnreadIDs = unreadStore.ids
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detectedUnreadIDs = (CodexDesktopUnreadReader.load() ?? [])
                .union(VSCodeUnreadReader.load() ?? [])
            let unreadIDs = storedUnreadIDs.union(detectedUnreadIDs)
            let result = Result { try StatusReader.load(unreadIDs: unreadIDs) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let tasks):
                    self.consecutiveFailures = 0
                    if self.tasks != tasks { self.tasks = tasks }
                    if self.errorMessage != nil { self.errorMessage = nil }
                case .failure(let error):
                    self.consecutiveFailures += 1
                    guard Self.shouldPublishError(after: self.consecutiveFailures) else { return }
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

private func windowFrame(fromAutosaveValue value: String) -> NSRect? {
    let fields = value.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 4,
          let x = Double(fields[0]), let y = Double(fields[1]),
          let width = Double(fields[2]), let height = Double(fields[3]),
          x.isFinite, y.isFinite, width > 0, height > 0 else { return nil }
    return NSRect(x: x, y: y, width: width, height: height)
}

struct TaskRow: View {
    let task: CodexTask
    let openTask: () -> Void

    private var statusLabel: String {
        task.isUnread ? "\(task.state.label)，未读" : task.state.label
    }

    var body: some View {
        Button(action: openTask) {
            HStack(spacing: 9) {
                Circle()
                    .fill(task.state.color)
                    .frame(width: 8, height: 8)
                Text(task.title)
                    .font(.system(size: 12.5, weight: task.isUnread ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(task.isUnread ? "未读" : task.state.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(task.isUnread ? Color.blue : Color.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开“\(task.title)”")
        .accessibilityLabel("打开 \(task.title)，\(statusLabel)")
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: TaskMonitor
    @ObservedObject var settings: AppSettings
    let isDesktop: Bool
    let openTask: (CodexTask) -> Void
    let showDesktop: () -> Void
    let showSettings: () -> Void

    private var visibleTasks: [CodexTask] {
        settings.showCompleted ? monitor.tasks : monitor.tasks.filter { $0.state != .green || $0.isUnread }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Circle()
                    .fill(monitor.aggregate?.color ?? Color.secondary.opacity(0.55))
                    .frame(width: 11, height: 11)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Codex，\(monitor.aggregate?.label ?? "暂无状态")")
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
                        TaskRow(task: task) {
                            openTask(task)
                        }
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
            HStack(spacing: 3) {
                Circle().fill(Color.blue).frame(width: 6, height: 6)
                Text("\(monitor.unreadCount)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let panelFrameKey = "CodexTrafficLightDesktopWindowFrame"
    private static let legacyPanelFrameKey = "NSWindow Frame CodexTrafficLightDesktopWindow"

    private let unreadStore: UnreadStore
    private let monitor: TaskMonitor
    private let unreadListener: CodexIPCUnreadListener
    private let settings = AppSettings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var popoverHost: NSHostingController<Dashboard>?
    private var panelHost: NSHostingController<Dashboard>?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let unreadStore = UnreadStore()
        self.unreadStore = unreadStore
        monitor = TaskMonitor(unreadStore: unreadStore)
        unreadListener = CodexIPCUnreadListener { threadID, unread in
            DispatchQueue.main.async { unreadStore.set(threadID, unread: unread) }
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        unreadListener.start()
        configureStatusItem()
        configurePopover()
        configurePanel()
        configureSettingsWindow()

        monitor.$tasks.combineLatest(monitor.$errorMessage)
            .sink { [weak self] tasks, errorMessage in
                // @Published emits before its stored value changes, so use the emitted snapshot here.
                self?.updateStatusItem(tasks: tasks, errorMessage: errorMessage)
                self?.resizeDashboards()
            }
            .store(in: &cancellables)
        settings.$showCompleted
            .sink { [weak self] _ in self?.resizeDashboards() }
            .store(in: &cancellables)
        settings.$alwaysOnTop
            .sink { [weak self] _ in self?.applyPanelLevel() }
            .store(in: &cancellables)

        updateStatusItem(tasks: monitor.tasks, errorMessage: monitor.errorMessage)
        if settings.showDesktopAtLaunch {
            DispatchQueue.main.async { [weak self] in self?.showDesktop(activate: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unreadListener.stop()
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
            openTask: { [weak self] task in
                self?.popover.performClose(nil)
                TaskNavigator.open(task)
            },
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
            openTask: { TaskNavigator.open($0) },
            showDesktop: {},
            showSettings: { [weak self] in self?.showSettings() }
        )
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
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

        var restoredFrame = false
        let savedFrame = UserDefaults.standard.string(forKey: Self.panelFrameKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyPanelFrameKey)
        if let value = savedFrame,
           let frame = windowFrame(fromAutosaveValue: value),
           NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            panel.setFrame(frame, display: false)
            restoredFrame = true
        }
        if !restoredFrame, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 18, y: visible.maxY - panel.frame.height - 18))
        }
        self.panel = panel
        panel.delegate = self
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

    private func updateStatusItem(tasks: [CodexTask], errorMessage: String?) {
        guard let button = statusItem.button else { return }
        let state = TaskMonitor.aggregate(for: tasks, errorMessage: errorMessage)
        button.image = MenuBarDot.image(for: state)
        let unreadCount = tasks.count { $0.isUnread }
        let stateDetail = state?.label ?? "没有任务"
        let detail = errorMessage == nil
            ? (unreadCount > 0 ? "\(stateDetail)，\(unreadCount) 条未读" : stateDetail)
            : "状态读取失败"
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
            let contentSize = host.view.fittingSize
            guard panel.contentView?.bounds.size != contentSize else { return }
            let oldTop = panel.frame.maxY
            panel.setContentSize(contentSize)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - panel.frame.height))
        }
    }

    private func applyPanelLevel() {
        panel?.isFloatingPanel = settings.alwaysOnTop
        panel?.level = settings.alwaysOnTop ? .floating : .normal
    }

    func windowDidMove(_ notification: Notification) {
        savePanelFrame(notification)
    }

    func windowDidResize(_ notification: Notification) {
        savePanelFrame(notification)
    }

    private func savePanelFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        let frame = window.frame
        UserDefaults.standard.set(
            "\(frame.minX) \(frame.minY) \(frame.width) \(frame.height)",
            forKey: Self.panelFrameKey
        )
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
    let approval = Data(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"a1","input":"const r = await tools.exec_command({\"sandbox_permissions\":\"require_escalated\"});"}}
        """#.utf8)
    let approved = Data(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"a1","input":"const r = await tools.exec_command({\"sandbox_permissions\":\"require_escalated\"});"}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"a1"}}
        """#.utf8)
    let approvalMention = Data(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call","status":"completed","name":"exec","call_id":"a1","input":"const r = await tools.exec_command({\"cmd\":\"rg \\\"sandbox_permissions\\\":\\\"require_escalated\\\" file\"});"}}
        """#.utf8)

    let running = Data("""
        {"type":"event_msg","payload":{"type":"task_started"}}
        """.utf8)
    let completed = Data("""
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8)

    precondition(StatusReader.signals(in: prompt).pendingUserAction)
    precondition(!StatusReader.signals(in: answered).pendingUserAction)
    precondition(StatusReader.signals(in: approval).pendingUserAction)
    precondition(!StatusReader.signals(in: approved).pendingUserAction)
    precondition(!StatusReader.signals(in: approvalMention).pendingUserAction)
    precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: running)) == .yellow)
    precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: approval)) == .red)
    precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: prompt)) == .red)
    precondition(StatusReader.classify(lockHeld: true, signals: StatusReader.signals(in: completed)) == .green)
    precondition(StatusReader.classify(lockHeld: false, signals: StatusReader.signals(in: running)) == .green)

    let now = Date()
    let green = CodexTask(id: "g", title: "green", state: .green, isUnread: false, cwd: "/tmp", rolloutPath: "/tmp/g", updatedAt: now)
    let yellow = CodexTask(id: "y", title: "yellow", state: .yellow, isUnread: false, cwd: "/tmp", rolloutPath: "/tmp/y", updatedAt: now)
    let red = CodexTask(id: "r", title: "red", state: .red, isUnread: false, cwd: "/tmp", rolloutPath: "/tmp/r", updatedAt: now)
    precondition(TaskMonitor.aggregate(for: [green, yellow, red], errorMessage: nil) == .red)
    precondition(TaskMonitor.aggregate(for: [], errorMessage: nil) == nil)
    precondition(TaskMonitor.aggregate(for: [red], errorMessage: "failed") == nil)

    precondition(!TaskMonitor.shouldPublishError(after: 1))
    precondition(TaskMonitor.shouldPublishError(after: 2))

    let sqliteTestDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-traffic-light-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: sqliteTestDirectory, withIntermediateDirectories: false)
    defer {
        StatusReader.closeDatabase()
        try? FileManager.default.removeItem(at: sqliteTestDirectory)
    }
    let sqliteTestURL = sqliteTestDirectory.appendingPathComponent("state.sqlite")
    var writer: OpaquePointer?
    precondition(sqlite3_open_v2(sqliteTestURL.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    precondition(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(1)", nil, nil, nil) == SQLITE_OK)
    func sampleValue(in database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, "SELECT value FROM sample", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        precondition(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }
    let persistentReader = try! StatusReader.openDatabase(at: sqliteTestURL)
    precondition(sampleValue(in: persistentReader) == 1)
    sqlite3_close(writer)
    precondition(FileManager.default.fileExists(atPath: sqliteTestURL.path + "-wal"))
    precondition(try! StatusReader.openDatabase(at: sqliteTestURL) == persistentReader)
    precondition(sampleValue(in: persistentReader) == 1)

    let nextSQLiteTestURL = sqliteTestDirectory.appendingPathComponent("state_2.sqlite")
    var nextWriter: OpaquePointer?
    precondition(sqlite3_open_v2(nextSQLiteTestURL.path, &nextWriter, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    precondition(sqlite3_exec(nextWriter, "CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(2)", nil, nil, nil) == SQLITE_OK)
    precondition(sampleValue(in: try! StatusReader.openDatabase(at: nextSQLiteTestURL)) == 2)
    sqlite3_close(nextWriter)

    let taskID = "01a0551f-9005-7ce2-b6f6-028df77a5997"
    precondition(TaskNavigator.codexThreadURL(taskID)?.absoluteString == "codex://threads/\(taskID)")
    precondition(TaskNavigator.codexThreadURL("bad") == nil)
    precondition(TaskNavigator.vscodeThreadURL(taskID)?.absoluteString == "vscode://openai.chatgpt/local/\(taskID)")
    precondition(TaskNavigator.vscodeWorkspaceURL("/Users/Newton/Project With Space")?.absoluteString == "file:///Users/Newton/Project%20With%20Space/")
    precondition(TaskNavigator.isVSCode(sessionHeader: Data(#"{"type":"session_meta","payload":{"originator":"codex_vscode"}}"#.utf8)))
    precondition(!TaskNavigator.isVSCode(sessionHeader: Data(#"{"type":"session_meta","payload":{"originator":"codex_work_desktop"}}"#.utf8)))
    precondition(windowFrame(fromAutosaveValue: "-514 1088 320 440 -1440 -324 1440 2530") == NSRect(x: -514, y: 1088, width: 320, height: 440))
    precondition(windowFrame(fromAutosaveValue: "broken") == nil)

    let unreadID = "01a0551f-9005-7ce2-b6f6-028df77a5997"
    let unreadJSON = Data(#"{"persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":["01a0551f-9005-7ce2-b6f6-028df77a5997","bad"]}}}"#.utf8)
    precondition(VSCodeUnreadReader.ids(in: unreadJSON) == [unreadID])
    let desktopUnreadJSON = Data(#"{"electron-persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":["01a0551f-9005-7ce2-b6f6-028df77a5997","bad"]}}}"#.utf8)
    precondition(CodexDesktopUnreadReader.ids(in: desktopUnreadJSON) == [unreadID])
    let broadcast: [String: Any] = [
        "type": "broadcast",
        "method": "thread-read-state-changed",
        "version": 2,
        "params": ["hostId": "local", "conversationId": unreadID, "hasUnreadTurn": false]
    ]
    var partialFrame = try! CodexIPCProtocol.frame(broadcast)
    let tail = partialFrame.subdata(in: 3..<partialFrame.count)
    partialFrame.removeSubrange(3..<partialFrame.count)
    precondition(try! CodexIPCProtocol.nextObject(from: &partialFrame) == nil)
    partialFrame.append(tail)
    let decoded = try! CodexIPCProtocol.nextObject(from: &partialFrame)
    let change = decoded.flatMap(CodexIPCProtocol.unreadChange)
    precondition(change?.threadID == unreadID && change?.unread == false && partialFrame.isEmpty)

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
    let unreadStore = UnreadStore(defaults: defaults) { [unreadID] }
    precondition(unreadStore.ids == [unreadID])
    unreadStore.set(unreadID, unread: false)
    precondition(UnreadStore(defaults: defaults) { [] }.ids.isEmpty)
    print("Codex Traffic Light self-test passed")
}

private func printLiveSnapshot() -> Never {
    do {
        let unreadIDs = (CodexDesktopUnreadReader.load() ?? [])
            .union(VSCodeUnreadReader.load() ?? [])
        let tasks = try StatusReader.load(unreadIDs: unreadIDs)
        let counts = Dictionary(grouping: tasks, by: \.state).mapValues(\.count)
        print("Live snapshot passed: \(tasks.count) tasks, red=\(counts[.red, default: 0]), yellow=\(counts[.yellow, default: 0]), green=\(counts[.green, default: 0]), unread=\(tasks.count { $0.isUnread })")
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
withExtendedLifetime(appDelegate) {
    application.run()
}
