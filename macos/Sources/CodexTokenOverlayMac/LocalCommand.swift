import Foundation

enum LocalCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 45,
                    environment: [String: String]? = nil, allowFailure: Bool = false) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = output
        process.standardError = errors
        let errorResult = CommandErrorBuffer()
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            errorResult.finish(errors.fileHandleForReading.readDataToEndOfFile())
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        defer { timer.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let failure = errorResult.wait()
        guard data.count <= 8 * 1024 * 1024 else {
            throw NSError(domain: "Command", code: 2, userInfo: [NSLocalizedDescriptionKey: "返回数据过大，请缩小统计范围。"])
        }
        if process.terminationStatus != 0 && !allowFailure {
            let message = String(decoding: failure, as: UTF8.self).split(separator: "\n").last.map(String.init)
            throw NSError(domain: "Command", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "操作超时或未完成，请重试。"])
        }
        return data
    }
}

private final class CommandErrorBuffer: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    func finish(_ value: Data) { data = value; finished.signal() }
    func wait() -> Data { finished.wait(); return data }
}
