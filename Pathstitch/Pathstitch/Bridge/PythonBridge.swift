import Foundation

enum PythonBridgeError: Error, LocalizedError {
    case processFailed(String)
    case invalidResponse(String)
    case timeout
    case executionError(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Python process failed: \(msg)"
        case .invalidResponse(let msg): return "Invalid JSON response: \(msg)"
        case .timeout: return "Python execution timed out (60s)"
        case .executionError(let msg): return "Error: \(msg)"
        }
    }
}

/// Swift side of the persistent geometry worker (Stage 1 of the file-streaming
/// plan; cf. Phase 3 / MAS-25, MAS-10).
///
/// Instead of spawning a fresh `python -m …` process per operation — which
/// re-imported `ezdxf` / `shapely` / `OCC` every time (~240 ms of pure startup,
/// the main loading-screen cause) — we launch **one** long-lived
/// `pathstitch_core.worker` and stream requests to it. Interactive ops then
/// cost single-digit milliseconds.
///
/// Wire protocol: length-prefixed frames `[4-byte big-endian uint32][UTF-8 JSON]`
/// in both directions. Requests carry a monotonic `id`; this actor multiplexes
/// many in-flight requests over the one pipe and demultiplexes responses back to
/// the awaiting callers. The worker is auto-restarted on crash or per-request
/// timeout, so a hung op can never wedge the app. The JSON payload is the same
/// `{op, args}` shape the old CLI used, so callers are unchanged and the codec
/// can later be swapped for MessagePack (Stage 2) by touching framing only.
actor PythonBridge {
    static let shared = PythonBridge()

    /// Resolved once. A distributed `.app` ships a self-contained Python env and a
    /// copy of `pathstitch_core` under `Contents/Resources/`, so it runs on any Mac
    /// with no conda/repo on disk. When running from Xcode (no bundled env) we fall
    /// back to the developer's conda env + repo checkout.
    private static let resolved: (python: String, projectPath: String) = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let py = res.appendingPathComponent("pyenv/bin/python3.11").path
            var isDir: ObjCBool = false
            let coreOK = fm.fileExists(atPath: res.appendingPathComponent("pathstitch_core").path,
                                       isDirectory: &isDir) && isDir.boolValue
            if fm.isExecutableFile(atPath: py) && coreOK {
                return (py, res.path)
            }
        }
        // Developer fallback (running from Xcode against the working tree).
        return ("/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python",
                "/Users/chen/Documents/Assets/Pathstitch")
    }()
    private var pythonPath: String { Self.resolved.python }
    private var projectPath: String { Self.resolved.projectPath }
    private let requestTimeoutNanos: UInt64 = 60_000_000_000 // 60s

    // Live worker state.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    /// Bumped on every (re)launch so stale readers/responses are ignored.
    private var workerGeneration: Int = 0

    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let onProgress: (@Sendable (Double) -> Void)?
    }
    private var pending: [Int: Pending] = [:]
    private var nextId: Int = 1

    /// Executes a worker operation and returns its JSON response dictionary.
    /// API-compatible with the previous per-spawn implementation.
    func run(
        module: String,
        op: String,
        args: [String: Any],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [String: Any] {
        try ensureWorker()

        let id = nextId
        nextId += 1
        let generation = workerGeneration

        let request: [String: Any] = ["id": id, "module": module, "op": op, "args": args]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            throw PythonBridgeError.executionError("Failed to serialize request arguments.")
        }
        let frame = PythonBridge.frame(body)

        // Per-request timeout watchdog — fails just this request and restarts the
        // worker if it is still the live one (a hung op must not back up the queue).
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.requestTimeoutNanos ?? 60_000_000_000)
            if Task.isCancelled { return }
            await self?.failTimedOut(id: id, generation: generation)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = Pending(continuation: cont, onProgress: onProgress)
            guard let handle = stdinHandle else {
                pending.removeValue(forKey: id)
                cont.resume(throwing: PythonBridgeError.processFailed("Worker stdin unavailable."))
                return
            }
            do {
                try handle.write(contentsOf: frame)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: PythonBridgeError.processFailed("Failed to send request: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Worker lifecycle

    /// Launches the worker if it isn't already running. Synchronous and
    /// actor-isolated, so concurrent callers can't double-launch.
    private func ensureWorker() throws {
        if let p = process, p.isRunning { return }

        // Tear down any dead worker before relaunching.
        readerTask?.cancel()
        readerTask = nil

        let stranded = pending
        pending.removeAll()
        for (_, p) in stranded {
            p.continuation.resume(throwing: PythonBridgeError.processFailed("Python worker exited unexpectedly."))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "pathstitch_core.worker"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = projectPath
        env["PYTHONUNBUFFERED"] = "1"
        // A stray PYTHONHOME in the user's shell would override the bundled env's
        // prefix and break a distributed build; the interpreter finds its own
        // stdlib relative to the executable, so drop it.
        env["PYTHONHOME"] = nil
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // Leave standardError inheriting the app's stderr so op debug output and
        // tracebacks surface in the console and can never fill/block a pipe.

        do {
            try proc.run()
        } catch {
            throw PythonBridgeError.processFailed("Failed to launch Python worker: \(error.localizedDescription)")
        }

        workerGeneration += 1
        let generation = workerGeneration
        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        let outHandle = outPipe.fileHandleForReading

        readerTask = Task.detached { [weak self] in
            await self?.readLoop(handle: outHandle, generation: generation)
        }
    }

    /// Reads response frames off the worker's stdout on a background executor and
    /// hands each to the actor. `nonisolated` so the blocking reads never run on
    /// (and stall) the actor.
    nonisolated private func readLoop(handle: FileHandle, generation: Int) async {
        while let frame = PythonBridge.readFrame(handle) {
            if let json = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] {
                await handleResponse(json: json, generation: generation)
            }
        }
        await handleWorkerExit(generation: generation)
    }

    private func handleResponse(json: [String: Any], generation: Int) {
        guard generation == workerGeneration else { return } // response from a retired worker
        guard let id = json["id"] as? Int, let p = pending[id] else { return }

        if (json["status"] as? String) == "progress" {
            if let progress = json["progress"] as? Double { p.onProgress?(progress) }
            return // keep the request pending until its final frame
        }

        pending.removeValue(forKey: id)
        if (json["status"] as? String) == "ok" {
            p.continuation.resume(returning: json)
        } else {
            let message = json["message"] as? String ?? "Unknown error from Python worker."
            p.continuation.resume(throwing: PythonBridgeError.executionError(message))
        }
    }

    private func handleWorkerExit(generation: Int) {
        guard generation == workerGeneration else { return }
        let failed = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        for (_, p) in failed {
            p.continuation.resume(throwing: PythonBridgeError.processFailed("Python worker exited unexpectedly."))
        }
        // The next run() will relaunch a fresh worker.
    }

    private func failTimedOut(id: Int, generation: Int) {
        guard let p = pending[id] else { return } // already answered
        pending.removeValue(forKey: id)
        p.continuation.resume(throwing: PythonBridgeError.timeout)
        // If this is still the live worker, it may be wedged on that op — restart
        // it so subsequent requests aren't stuck behind a hang.
        if generation == workerGeneration {
            restartWorker()
        }
    }

    private func restartWorker() {
        let dying = process
        let stranded = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        readerTask?.cancel()
        readerTask = nil
        workerGeneration += 1 // retire the old reader and any late responses
        dying?.terminate()
        for (_, p) in stranded {
            p.continuation.resume(throwing: PythonBridgeError.processFailed("Python worker was restarted."))
        }
    }

    /// Shuts down the persistent worker process.
    func shutdown() {
        let dying = process
        let stranded = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        readerTask?.cancel()
        readerTask = nil
        workerGeneration += 1
        dying?.terminate()
        for (_, p) in stranded {
            p.continuation.resume(throwing: PythonBridgeError.processFailed("Python worker was shut down."))
        }
    }

    // MARK: - Framing helpers (nonisolated, pure)

    /// Prepends a 4-byte big-endian length header to a JSON body.
    nonisolated private static func frame(_ body: Data) -> Data {
        let len = UInt32(body.count)
        var out = Data(capacity: 4 + body.count)
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(body)
        return out
    }

    /// Reads one length-prefixed frame, blocking until complete. Returns nil on EOF.
    nonisolated private static func readFrame(_ handle: FileHandle) -> Data? {
        guard let header = readExactly(handle, 4) else { return nil }
        let bytes = [UInt8](header)
        let len = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        if len == 0 { return Data() }
        return readExactly(handle, Int(len))
    }

    /// Reads exactly `n` bytes, looping over short reads. Returns nil on EOF/error.
    nonisolated private static func readExactly(_ handle: FileHandle, _ n: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(n)
        while data.count < n {
            let chunk = (try? handle.read(upToCount: n - data.count)) ?? nil
            guard let chunk, !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }
}
