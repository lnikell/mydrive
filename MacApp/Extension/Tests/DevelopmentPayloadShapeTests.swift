#if MYDRIVE_DEVELOPMENT
import Darwin
import Foundation

enum DevelopmentPayloadShapeTests {
    static func run() throws -> Int {
        let absent = DevelopmentPayloadShape.inspect(nil, contentType: String(repeating: "x", count: 256))
        guard absent.kind == "none", absent.size == -1, absent.errorCode == 0, absent.contentType.count == 128 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("synthetic".utf8).write(to: file)
        let regular = DevelopmentPayloadShape.inspect(file, contentType: "com.apple.rtfd")
        guard regular.kind == "regular_file", regular.size == 9, regular.errorCode == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = DevelopmentPayloadShape.inspect(root, contentType: String(repeating: "x", count: 256))
        guard directory.kind == "directory", directory.errorCode == 0, directory.contentType.count == 128 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let symlink = DevelopmentPayloadShape.inspect(link, contentType: "public.symlink")
        guard symlink.kind == "open_failed", symlink.errorCode == ELOOP, symlink.size == -1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fifo = root.appendingPathComponent("fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let clock = ContinuousClock(), before = clock.now
        let pipe = DevelopmentPayloadShape.inspect(fifo, contentType: "public.data")
        guard pipe.kind == "fifo", pipe.errorCode == 0, before.duration(to: clock.now) < .seconds(1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS development payload shape distinguishes files/directories without content reads, symlink traversal or FIFO blocking")
        return 1
    }
}
#endif
