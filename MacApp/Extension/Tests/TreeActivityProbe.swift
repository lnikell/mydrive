import Foundation

actor TreeActivityProbe {
    private var running: [UUID: Progress] = [:]
    private var started = 0
    private var finished = 0
    private var failures = 0
    private var paths: [String] = []

    func record(_ event: TreeTransferEvent) {
        switch event {
        case .started(let id, _, let path, _, let progress):
            if running[id] != nil { failures += 1 }
            running[id] = progress; started += 1; paths.append(path)
        case .finished(let id, let error):
            finished += 1
            let progress = running.removeValue(forKey: id)
            if error != nil || progress?.isFinished != true { failures += 1 }
        }
    }

    func snapshot() -> (started: Int, finished: Int, failures: Int, paths: [String]) {
        (started, finished, failures, paths)
    }
}
