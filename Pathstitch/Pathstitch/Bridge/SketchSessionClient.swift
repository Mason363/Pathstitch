import Foundation

enum SketchSessionError: Error, LocalizedError {
    case noSession
    var errorDescription: String? { "No live sketch session." }
}

/// Swift side of the stateful sketch-constraint session (live drag solving).
///
/// The Python worker holds the ezdxf doc + constraint system in memory between
/// drag frames (`sketch_constraints.SketchSession`), so a drag frame costs one
/// worker round-trip and a ~2 ms solve — no file I/O until commit. This client
/// serializes the traffic: **one request in flight, latest drag target wins**
/// (intermediate frames are coalesced away), and any transport error marks the
/// session dead (worker restart wipes Python-side state, so there is nothing
/// to recover — the owner aborts the drag and reloads).
@MainActor
final class SketchSessionClient {
    private(set) var sessionId: String?
    private var pendingDrag: [String: Any]? = nil
    private var dragTask: Task<Void, Never>? = nil
    private var dead = false

    /// Called on the main actor with each drag frame's result: patched
    /// entities, fresh diagnostics, and whether the solver reverted the frame.
    var onPatch: (([DXFEntity], SolveDiagnostics?, _ reverted: Bool) -> Void)?
    /// Called once if the session is lost mid-drag (worker restart/crash).
    var onSessionLost: (() -> Void)?

    var isLive: Bool { sessionId != nil && !dead }

    func open(input: URL, constraints: [SketchConstraint]) async throws -> SolveDiagnostics? {
        dead = false
        // Deliberately keep any pendingDrag queued before/while opening — the
        // target is absolute, so the newest frame is all that matters.
        let res = try await PythonBridge.shared.run(
            module: "sketch_constraints",
            op: "session_open",
            args: ["input": input.path,
                   "constraints": constraints.map { $0.asDictionary }]
        )
        let data = res["data"] as? [String: Any] ?? [:]
        sessionId = data["session_id"] as? String
        guard sessionId != nil else { throw SketchSessionError.noSession }
        pump() // a drag may have been queued while opening
        return AppState.decodeDiagnostics(data["diagnostics"])
    }

    /// Fire-and-coalesce: stores the newest target and pumps the send loop.
    func drag(handle: String, role: String, target: CGPoint, anchor: CGPoint) {
        guard !dead else { return }
        pendingDrag = [
            "handle": handle,
            "role": role,
            "target": [Double(target.x), Double(target.y)],
            "anchor": [Double(anchor.x), Double(anchor.y)],
        ]
        pump()
    }

    private func pump() {
        guard dragTask == nil, !dead, let sid = sessionId, let payload = pendingDrag else { return }
        pendingDrag = nil
        dragTask = Task { @MainActor in
            do {
                let res = try await PythonBridge.shared.run(
                    module: "sketch_constraints",
                    op: "session_drag",
                    args: ["session_id": sid, "drag": payload]
                )
                let data = res["data"] as? [String: Any] ?? [:]
                let ents = Self.decodeEntities(data["entities"])
                let diag = AppState.decodeDiagnostics(data["diagnostics"])
                let reverted = data["reverted"] as? Bool ?? false
                onPatch?(ents, diag, reverted)
            } catch {
                dead = true
                sessionId = nil
                pendingDrag = nil
                onSessionLost?()
            }
            dragTask = nil
            pump() // drain a target that arrived while this frame was in flight
        }
    }

    /// Final polish solve + file write on the Python side; closes the session.
    func commit(output: URL) async throws -> ([DXFEntity], SolveDiagnostics?) {
        pendingDrag = nil
        if let t = dragTask { await t.value } // drain the in-flight frame first
        guard let sid = sessionId, !dead else { throw SketchSessionError.noSession }
        sessionId = nil
        let res = try await PythonBridge.shared.run(
            module: "sketch_constraints",
            op: "session_commit",
            args: ["session_id": sid, "output": output.path]
        )
        let data = res["data"] as? [String: Any] ?? [:]
        return (Self.decodeEntities(data["entities"]),
                AppState.decodeDiagnostics(data["diagnostics"]))
    }

    /// Closes the session without writing. Safe to call in any state.
    func abort() async {
        pendingDrag = nil
        if let t = dragTask { await t.value }
        guard let sid = sessionId else { return }
        sessionId = nil
        _ = try? await PythonBridge.shared.run(
            module: "sketch_constraints",
            op: "session_abort",
            args: ["session_id": sid]
        )
    }

    private static func decodeEntities(_ json: Any?) -> [DXFEntity] {
        guard let arr = json as? [[String: Any]], !arr.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: arr),
              let ents = try? JSONDecoder().decode([DXFEntity].self, from: data) else { return [] }
        return ents
    }
}
