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
    func run(host: String, script: String, timeout: TimeInterval) async -> RunResult
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
                 "sh -c " + shellQuote(script)]
        return args
    }

    public func run(host: String, script: String, timeout: TimeInterval) async -> RunResult {
        if host == localHost {
            return await runProcess("/bin/sh", ["-c", script], timeout: timeout)
        }
        return await runProcess("/usr/bin/ssh", sshArguments(host: host, script: script), timeout: timeout)
    }
}

/// Runs a process with a hard timeout. Output is collected incrementally and the result is
/// returned when the process *exits* — not at pipe EOF, because a ControlPersist master forked
/// by ssh can keep the stderr pipe open indefinitely.
public func runProcess(_ path: String, _ args: [String], timeout: TimeInterval,
                       environment: [String: String]? = nil) async -> RunResult {
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
        p.standardInput = FileHandle.nullDevice

        let box = OutputBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData, err: false) }
        errPipe.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData, err: true) }

        let finished = ResumeOnce()
        p.terminationHandler = { proc in
            // Drain whatever is already buffered without waiting for EOF.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            box.append(drainNonBlocking(outPipe.fileHandleForReading), err: false)
            box.append(drainNonBlocking(errPipe.fileHandleForReading), err: true)
            let (o, e) = box.strings()
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

    func append(_ d: Data, err isErr: Bool) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if isErr { err.append(d) } else { out.append(d) }
    }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func strings() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
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
