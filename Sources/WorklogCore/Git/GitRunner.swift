import Foundation

public struct GitResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public struct GitError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Limits how many git processes run at once.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// The only place that spawns `git`. Read-only usage everywhere except an optional fetch.
public final class GitRunner: Sendable {
    public let gitPath: String
    private let limiter: AsyncSemaphore

    public init(gitPath: String = "/usr/bin/git", maxConcurrent: Int = 4) {
        self.gitPath = gitPath
        self.limiter = AsyncSemaphore(maxConcurrent)
    }

    /// Runs `git -C <repo> <args>`. Throws only if the process can't start; check `status` for git failures.
    public func run(_ args: [String], repo: String? = nil, stdin: Data? = nil) async throws -> GitResult {
        await limiter.wait()
        defer { Task { await limiter.signal() } }

        var fullArgs: [String] = []
        if let repo { fullArgs += ["-C", repo] }
        fullArgs += ["--no-pager", "-c", "core.quotepath=off", "-c", "color.ui=never"]
        fullArgs += args

        let gitPath = self.gitPath
        let processArgs = fullArgs
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = processArgs
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "C"
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe: Pipe? = stdin == nil ? nil : Pipe()
                process.standardInput = inPipe ?? FileHandle.nullDevice

                do { try process.run() } catch {
                    continuation.resume(throwing: GitError("Couldn't run git: \(error.localizedDescription)"))
                    return
                }
                if let inPipe, let stdin {
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: GitResult(status: process.terminationStatus, stdout: out, stderr: errBox.data))
            }
        }
    }
}
