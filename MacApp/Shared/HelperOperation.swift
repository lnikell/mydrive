import Foundation
import Darwin

enum HelperOperationError: LocalizedError {
    case frameTooLarge, incompleteFrame, timedOut, failedExit(Int32), oversizedInput

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: "The NAS helper exceeded its response limit."
        case .incompleteFrame: "The NAS helper returned an incomplete response."
        case .timedOut: "The NAS helper stopped responding."
        case .failedExit: "The NAS helper ended unexpectedly."
        case .oversizedInput: "The NAS request exceeds the supported size."
        }
    }
}

/// Framing owns the size limit before bytes enter its retained buffer. The
/// caller supplies bounded chunks; no newline is required to enforce the cap.
struct HelperFrameParser {
    private var pending = Data()
    let maximumBytes: Int

    init(maximumBytes: Int = 8 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    mutating func append(_ chunk: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 10 {
            try retain(chunk[start..<index])
            guard !pending.isEmpty else { throw HelperOperationError.incompleteFrame }
            frames.append(pending)
            pending = Data()
            start = chunk.index(after: index)
        }
        try retain(chunk[start..<chunk.endIndex])
        return frames
    }

    func finish() throws {
        guard pending.isEmpty else { throw HelperOperationError.incompleteFrame }
    }

    private mutating func retain(_ bytes: Data.SubSequence) throws {
        guard bytes.count <= maximumBytes - pending.count else { throw HelperOperationError.frameTooLarge }
        pending.append(bytes)
    }
}

/// One operation owns launch, input, bounded output and process termination.
/// Returning from failure/cancellation means the child has been reaped.
enum HelperOperation {
    static func run(
        executable: URL, arguments: [String], input: Data,
        idleTimeout: TimeInterval = 60,
        onFrame: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard input.count <= 65_536 else { throw HelperOperationError.oversizedInput }
        try Task.checkCancellation()
        let child = try HelperProcess(executable: executable, arguments: arguments, idleTimeout: idleTimeout)
        defer { child.close() }
        try await withTaskCancellationHandler {
            do {
                try child.start(input: input)
                var parser = HelperFrameParser()
                while let chunk = try await child.readChunk(), !chunk.isEmpty {
                    try Task.checkCancellation()
                    for frame in try parser.append(chunk) { try await onFrame(frame) }
                }
                try parser.finish()
                child.outputFinished()
                let status = await child.waitForExit()
                try child.checkFailure()
                guard status == 0 else { throw HelperOperationError.failedExit(status) }
            } catch {
                child.stop(error)
                if child.wasLaunched { _ = await child.waitForExit() }
                throw error
            }
        } onCancel: { child.stop(CancellationError()) }
    }
}

/// Foundation Process and FileHandle remain behind a lock and dedicated blocking
/// I/O queues. Continuations are removed under the lock before any resumption.
private final class HelperProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "local.mydrive.helper.read", qos: .utility)
    private let inputQueue = DispatchQueue(label: "local.mydrive.helper.input", qos: .utility)
    private let idleTimeout: TimeInterval
    private let readDescriptor: Int32
    private var launched = false
    private var finished = false
    private var failure: (any Error)?
    private var exitStatus: Int32?
    private var exitWaiter: CheckedContinuation<Int32, Never>?
    private var readWaiter: CheckedContinuation<Data?, any Error>?
    private var watchdog: DispatchWorkItem?
    private var watchdogGeneration: UInt64 = 0
    private var terminateWatchdog: DispatchWorkItem?
    private var killWatchdog: DispatchWorkItem?

    init(executable: URL, arguments: [String], idleTimeout: TimeInterval) throws {
        self.idleTimeout = max(0.05, idleTimeout)
        readDescriptor = Darwin.dup(output.fileHandleForReading.fileDescriptor)
        guard readDescriptor >= 0 else { throw POSIXError(.EMFILE) }
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    var wasLaunched: Bool { lock.withLock { launched } }

    func start(input bytes: Data) throws {
        try lock.withLock {
            if let failure { throw failure }
            process.terminationHandler = { [weak self] task in self?.didExit(task.terminationStatus) }
            try process.run()
            launched = true
        }
        armWatchdog(after: idleTimeout)
        inputQueue.async { [self] in
            do {
                try input.fileHandleForWriting.write(contentsOf: bytes)
                try input.fileHandleForWriting.close()
            } catch { stop(error) }
        }
    }

    func readChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock {
                if let failure { continuation.resume(throwing: failure); return false }
                readWaiter = continuation
                return true
            }
            guard accepted else { return }
            readQueue.async { [self] in
                let result = Result { try readAvailableChunk() }
                let waiter = lock.withLock { let value = readWaiter; readWaiter = nil; return value }
                if case .success(let data) = result, data?.isEmpty == false { armWatchdog(after: idleTimeout) }
                waiter?.resume(with: result)
            }
        }
    }

    func outputFinished() { armWatchdog(after: 3) }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let exitStatus { continuation.resume(returning: exitStatus) }
                else { exitWaiter = continuation }
            }
        }
    }

    func checkFailure() throws {
        try lock.withLock { if let failure { throw failure } }
    }

    func stop(_ error: any Error, ifGeneration expected: UInt64? = nil) {
        let shouldSignal = lock.withLock {
            guard !finished, failure == nil else { return false }
            if let expected, expected != watchdogGeneration { return false }
            failure = error
            watchdog?.cancel()
            let waiter = readWaiter
            readWaiter = nil
            waiter?.resume(throwing: error)
            return launched && exitStatus == nil
        }
        guard shouldSignal else { return }
        if process.isRunning { process.interrupt() }
        let terminate = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
        }
        let kill = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
        lock.withLock { terminateWatchdog = terminate; killWatchdog = kill }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: terminate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: kill)
    }

    func close() {
        lock.withLock {
            finished = true
            watchdog?.cancel()
            terminateWatchdog?.cancel()
            killWatchdog?.cancel()
        }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        // A cancelled read may still be unwinding after its continuation was
        // resumed. Close its duplicate only after that blocking read returns.
        readQueue.async { [self] in Darwin.close(readDescriptor) }
    }

    private func readAvailableChunk() throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(readDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func didExit(_ status: Int32) {
        let waiter = lock.withLock {
            exitStatus = status
            terminateWatchdog?.cancel()
            killWatchdog?.cancel()
            let value = exitWaiter
            exitWaiter = nil
            return value
        }
        waiter?.resume(returning: status)
    }

    private func armWatchdog(after seconds: TimeInterval) {
        let timer: DispatchWorkItem? = lock.withLock {
            guard !finished, failure == nil else { return nil }
            watchdog?.cancel()
            watchdogGeneration &+= 1
            let generation = watchdogGeneration
            let timer = DispatchWorkItem { [weak self] in
                self?.stop(HelperOperationError.timedOut, ifGeneration: generation)
            }
            watchdog = timer
            return timer
        }
        if let timer { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer) }
    }
}
