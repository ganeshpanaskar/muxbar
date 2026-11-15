import Foundation

public struct RunResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool

    public var ok: Bool { exitCode == 0 && !timedOut }

    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

/// Runs a POSIX `sh` script on a host: locally via /bin/sh, remotely via /usr/bin/ssh.
public protocol ScriptRunner: Sendable {
    func run(host: String, script: String, timeout: TimeInterval, stdin: Data?) async -> RunResult
}

extension ScriptRunner {
    public func run(host: String, script: String, timeout: TimeInterval) async -> RunResult {
        await run(host: host, script: script, timeout: timeout, stdin: nil)
    }
}

/// Foundation's Process passes arguments in decomposed Unicode (NFD): "É" arrives as "E" + U+0301,
/// which is a different file name on Linux and matches nothing in NFC text. Scripts with
/// non-ASCII characters therefore travel base64-encoded and are decoded on the host; `eval` keeps
/// the script's stdin free (uploads read it).
public func asciiSafeScript(_ script: String) -> String {
    guard script.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return script }
    let b64 = Data(script.utf8).base64EncodedString()
    return "eval \"$(printf '%s' '\(b64)' | base64 -d)\""
}

/// Runs a script with /bin/sh on this Mac (non-ASCII-safe).
public func runLocalScript(_ script: String, timeout: TimeInterval, environment: [String: String]? = nil,
                           stdin: Data? = nil) async -> RunResult {
    await runProcess("/bin/sh", ["-c", asciiSafeScript(script)], timeout: timeout, environment: environment, stdin: stdin)
}

public struct SystemRunner: ScriptRunner {
    public var sshConfigFile: String?

    public init(sshConfigFile: String? = nil) { self.sshConfigFile = sshConfigFile }

    /// Non-interactive ssh options. BatchMode means a credential prompt fails fast instead of
    /// hanging; ControlMaster reuse keeps polling cheap over slow links.
    public func sshArguments(host: String, script: String) -> [String] {
        var args: [String] = []
        if let f = sshConfigFile { args += ["-F", f] }
        args += ["-o", "BatchMode=yes",
                 "-o", "ConnectTimeout=10",
                 "-o", "ServerAliveInterval=15",
                 "-o", "ServerAliveCountMax=2",
                 "-o", "ControlMaster=auto",
                 "-o", "ControlPath=\(MuxbarPaths.controlPath)",
                 "-o", "ControlPersist=10m",
                 "-T", "--", host,
                 // The remote login shell may be zsh/bash; run our script under sh explicitly.
                 "sh -c " + shellQuote(asciiSafeScript(script))]
        return args
    }

    public func run(host: String, script: String, timeout: TimeInterval, stdin: Data?) async -> RunResult {
        if host == localHost {
            return await runLocalScript(script, timeout: timeout, stdin: stdin)
        }
        return await runProcess("/usr/bin/ssh", sshArguments(host: host, script: script), timeout: timeout, stdin: stdin)
    }
}

/// Runs a process with a hard timeout. Output is collected incrementally and the result is
/// returned when the process *exits* — not at pipe EOF, because a ControlPersist master forked
/// by ssh can keep the stderr pipe open indefinitely.
/// - Parameter stdin: bytes fed to the process (e.g. a file being uploaded); nil = /dev/null.
public func runProcess(_ path: String, _ args: [String], timeout: TimeInterval,
                       environment: [String: String]? = nil, stdin: Data? = nil) async -> RunResult {
    await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = environment ?? ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH + ":" + (env["PATH"] ?? "")
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice

        let box = OutputBox()
        // Raw read(2) instead of FileHandle.availableData: availableData raises an Objective-C
        // exception (abort) when the fd is non-blocking and empty, which happens when the drain
        // below races a still-running readability callback.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        outPipe.fileHandleForReading.readabilityHandler = { _ in box.read(outFD, err: false) }
        errPipe.fileHandleForReading.readabilityHandler = { _ in box.read(errFD, err: true) }

        let finished = ResumeOnce()
        p.terminationHandler = { proc in
            // Drain whatever is already buffered without waiting for EOF.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let (o, e) = box.drainAndSnapshot(outPipe.fileHandleForReading, errPipe.fileHandleForReading)
            finished.once {
                cont.resume(returning: RunResult(stdout: o, stderr: e, exitCode: proc.terminationStatus,
                                                 timedOut: box.timedOut))
            }
        }
        do {
            try p.run()
        } catch {
            finished.once {
                cont.resume(returning: RunResult(stdout: "", stderr: "failed to launch \(path): \(error)",
                                                 exitCode: 127, timedOut: false))
            }
            return
        }
        if let inPipe, let stdin {
            // Written from a background queue: a large upload must not block the caller.
            DispatchQueue.global().async {
                let h = inPipe.fileHandleForWriting
                try? h.write(contentsOf: stdin)
                try? h.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard p.isRunning else { return }
            box.markTimedOut()
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// One read(2) of whatever is available; empty on EAGAIN/EOF/error (never throws).
private func readAvailable(_ fd: Int32) -> Data {
    var buf = [UInt8](repeating: 0, count: 65536)
    let n = read(fd, &buf, buf.count)
    return n > 0 ? Data(buf[0..<n]) : Data()
}

private func drainNonBlocking(_ h: FileHandle) -> Data {
    let fd = h.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return data
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private(set) var timedOut = false

    /// A read and its append happen under the lock: otherwise the final drain can run between a
    /// callback's read and its append, and the snapshot misses that output.
    func read(_ fd: Int32, err isErr: Bool) {
        lock.lock(); defer { lock.unlock() }
        let d = readAvailable(fd)
        if isErr { err.append(d) } else { out.append(d) }
    }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    /// Whatever is already buffered (without waiting for EOF), then everything read so far.
    func drainAndSnapshot(_ o: FileHandle, _ e: FileHandle) -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        out.append(drainNonBlocking(o))
        err.append(drainNonBlocking(e))
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func once(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}
