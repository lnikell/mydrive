import Foundation
import Darwin

private enum TestFailure: Error { case failed(String), consumer }
private actor Frames {
    var values: [String] = []
    func append(_ data: Data) { values.append(String(decoding: data, as: UTF8.self)) }
    func first() -> String? { values.first }
    func all() -> [String] { values }
}

@main struct HelperOperationTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure.failed(message) }
    }

    static func main() async throws {
        var parser = HelperFrameParser(maximumBytes: 8)
        try check(try parser.append(Data("1234".utf8)).isEmpty, "partial frame published")
        let completed = try parser.append(Data("5678\nx\ny\n".utf8))
        try check(completed.map { String(decoding: $0, as: UTF8.self) } == ["12345678", "x", "y"], "chunk framing")
        try parser.finish()
        do {
            _ = try parser.append(Data("123456789".utf8))
            throw TestFailure.failed("unterminated oversized frame accepted")
        } catch HelperOperationError.frameTooLarge { }
        var incomplete = HelperFrameParser()
        _ = try incomplete.append(Data("partial".utf8))
        do { try incomplete.finish(); throw TestFailure.failed("partial EOF accepted") }
        catch HelperOperationError.incompleteFrame { }
        print("PASS bounded frame parsing and incomplete EOF")

        let frames = Frames()
        try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                      arguments: ["-c", "cat >/dev/null; printf 'first\\nsecond\\n'"],
                                      input: Data("test-only".utf8)) { await frames.append($0) }
        let values = await frames.all()
        try check(values == ["first", "second"], "success output not fully drained")
        print("PASS success drains frames and reaps")

        let maximumFrames = Frames()
        var maximumInput = Data(repeating: 65, count: 65_535)
        maximumInput.append(10)
        try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], input: maximumInput) { await maximumFrames.append($0) }
        let maximumOutput = await maximumFrames.all()
        try check(maximumOutput.count == 1 && maximumOutput[0].utf8.count == 65_535, "Maximum request was not drained")
        do {
            try await HelperOperation.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [], input: Data(repeating: 65, count: 65_537)) { _ in }
            throw TestFailure.failed("Oversized request reached a helper")
        } catch HelperOperationError.oversizedInput { }
        print("PASS 64 KiB input boundary and oversized request rejection")

        for attempt in 0..<20 {
            do {
                try await HelperOperation.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                    arguments: [], input: Data(repeating: 65, count: attempt.isMultiple(of: 2) ? 4096 : 65_536)) { _ in }
                throw TestFailure.failed("early failed exit succeeded")
            } catch is HelperOperationError { }
            catch is POSIXError { }
        }
        print("PASS early helper exit while writing stdin")

        let pidFrames = Frames()
        let child = Task {
            try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' INT TERM; printf '%s\\n' \"$$\"; while :; do :; done"], input: Data()) {
                await pidFrames.append($0)
            }
        }
        var pid: Int32?
        for _ in 0..<100 {
            if let value = await pidFrames.first() { pid = Int32(value); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pid else {
            child.cancel()
            _ = try? await child.value
            throw TestFailure.failed("child did not start")
        }
        let cancelledAt = Date()
        child.cancel()
        do { try await child.value; throw TestFailure.failed("cancelled operation succeeded") }
        catch is CancellationError { }
        try check(Date().timeIntervalSince(cancelledAt) < 4, "cancellation did not escalate promptly")
        try check(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "cancel returned before child was reaped")
        print("PASS cancellation escalates and reaps an uncooperative helper")

        let started = Date()
        do {
            try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' INT TERM; while :; do :; done"], input: Data(), idleTimeout: 0.1) { _ in }
            throw TestFailure.failed("idle helper succeeded")
        } catch HelperOperationError.timedOut { }
        try check(Date().timeIntervalSince(started) < 4, "idle timeout did not reap")
        print("PASS idle watchdog bounds an unresponsive helper")

        do {
            try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' INT TERM; printf 'frame\\n'; while :; do :; done"], input: Data()) { _ in
                throw TestFailure.consumer
            }
            throw TestFailure.failed("consumer failure swallowed")
        } catch TestFailure.consumer { }
        print("PASS consumer failure keeps its error and reaps")
    }
}
