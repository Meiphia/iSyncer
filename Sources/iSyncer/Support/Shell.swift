import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    var output: String { String(decoding: stdout, as: UTF8.self) }
    var ok: Bool { status == 0 }
}

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    private final class Box: @unchecked Sendable { var data = Data() }

    /// Runs a process to completion on a background thread.
    static func run(_ executable: String, _ args: [String]) async throws -> ShellResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executable, args)
        }.value
    }

    static func runSync(_ executable: String, _ args: [String]) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()

        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, stdout: outData,
                           stderr: String(decoding: errBox.data, as: UTF8.self))
    }


}

enum Tools {
    private static let searchDirs: [String] = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        return dirs
    }()

    static func find(_ name: String) -> String? {
        for dir in searchDirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Supports older app bundles and locally installed FFmpeg.
    static let ffmpeg: String? = {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return find("ffmpeg")
    }()
}
