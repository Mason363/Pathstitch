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

class PythonBridge {
    static let shared = PythonBridge()
    
    private let pythonPath = "/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python"
    
    /// Executes a Python module operation with arguments, streaming progress updates to onProgress.
    func run(
        module: String,
        op: String,
        args: [String: Any],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "pathstitch_core.\(module)"]
        
        // Configure PYTHONPATH and current directory to locate pathstitch_core package
        let projectPath = "/Users/chen/Documents/Assets/Pathstitch"
        if FileManager.default.fileExists(atPath: projectPath) {
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            var env = ProcessInfo.processInfo.environment
            let currentPythonPath = env["PYTHONPATH"] ?? ""
            env["PYTHONPATH"] = currentPythonPath.isEmpty ? projectPath : "\(projectPath):\(currentPythonPath)"
            process.environment = env
        }
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        let payload: [String: Any] = ["op": op, "args": args]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonBridgeError.executionError("Failed to serialize input arguments.")
        }
        
        try process.run()
        
        // Write arguments to stdin
        if let data = (jsonString + "\n").data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            try stdinPipe.fileHandleForWriting.close()
        }
        
        // Run background reading task
        let outputTask = Task<[String: Any], Error> {
            let reader = LineReader(fileHandle: stdoutPipe.fileHandleForReading)
            var finalResult: [String: Any]?
            
            for try await line in reader {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                
                if let status = json["status"] as? String {
                    if status == "progress", let progressVal = json["progress"] as? Double {
                        onProgress?(progressVal)
                    } else if status == "ok" {
                        finalResult = json
                    } else if status == "error" {
                        let msg = json["message"] as? String ?? "Unknown error"
                        throw PythonBridgeError.executionError(msg)
                    }
                }
            }
            
            if let result = finalResult {
                return result
            } else {
                // If standard output didn't yield a final result, check stderr
                let errData = try stderrPipe.fileHandleForReading.readToEnd()
                let errMsg = errData.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw PythonBridgeError.processFailed(errMsg.isEmpty ? "No output from python script" : errMsg)
            }
        }
        
        // Run timeout task
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 60_000_000_000) // 60s timeout
            process.terminate()
            outputTask.cancel()
        }
        
        do {
            let result = try await outputTask.value
            timeoutTask.cancel()
            return result
        } catch {
            timeoutTask.cancel()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }
}

/// Helper actor/sequence to read lines from a FileHandle asynchronously
private struct LineReader: AsyncSequence {
    typealias Element = String
    let fileHandle: FileHandle
    
    struct AsyncIterator: AsyncIteratorProtocol {
        let fileHandle: FileHandle
        var buffer = Data()
        
        mutating func next() async throws -> String? {
            while true {
                if let lineEndIndex = buffer.firstIndex(of: 10) { // '\n' = 10
                    let lineData = buffer.subdata(in: 0..<lineEndIndex)
                    buffer.removeSubrange(0...lineEndIndex)
                    return String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .newlines)
                }
                
                // Read next chunk
                guard let chunk = try? fileHandle.read(upToCount: 4096), !chunk.isEmpty else {
                    // EOF
                    if !buffer.isEmpty {
                        let line = String(data: buffer, encoding: .utf8)
                        buffer.removeAll()
                        return line?.trimmingCharacters(in: .newlines)
                    }
                    return nil
                }
                buffer.append(chunk)
            }
        }
    }
    
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(fileHandle: fileHandle)
    }
}
