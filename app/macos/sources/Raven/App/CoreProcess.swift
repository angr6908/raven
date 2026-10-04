import Foundation

@MainActor
final class CoreProcess {
    static let shared = CoreProcess()

    private var started = false
    private var process: Process?
    private var lifeline: Pipe?
    private var readiness: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    private static var executable: URL? {
        Bundle.main.url(forResource: "raven", withExtension: nil)
    }

    private static var logFile: URL {
        URL.homeDirectory
            .appending(path: "Library")
            .appending(path: "Logs")
            .appending(path: "Raven", directoryHint: .isDirectory)
            .appending(path: "core.log")
    }

    func start() {
        guard !started, let executable = Self.executable else { return }
        started = true
        guard !Self.isListening(), let pid = launch(executable) else { return }
        readiness = Task.detached { await Self.waitForListener(pid: pid) }
    }

    func waitUntilReady() async {
        await readiness?.value
    }

    func stop() async {
        guard let child = process, child.isRunning else { return }
        let pid = child.processIdentifier
        child.terminate()
        let killer = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { kill(pid, SIGKILL) }
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        killer.cancel()
    }

    private func didExit() {
        process = nil
        lifeline = nil
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func launch(_ executable: URL) -> pid_t? {
        guard process == nil else { return nil }
        do {
            try ProviderStore.ensureConfigDirectory()
            let data = ProviderStore.configDirectory.path(percentEncoded: false)
            let child = Process()
            child.executableURL = executable
            child.arguments = ["-working-dir", data, "-data-dir", data, "-exit-on-stdin-close"]
            let pipe = Pipe()
            child.standardInput = pipe
            let output = Self.openLog()
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { _ in
                Task { @MainActor in CoreProcess.shared.didExit() }
            }
            try child.run()
            process = child
            lifeline = pipe
            return child.processIdentifier
        } catch {
            process = nil
            return nil
        }
    }

    private static func openLog() -> FileHandle {
        let url = logFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        let handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
        _ = try? handle.seekToEnd()
        return handle
    }

    private nonisolated static func waitForListener(pid: pid_t) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, kill(pid, 0) == 0, !isListening() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private nonisolated static func isListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = LocalProxy.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 250) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }
}
