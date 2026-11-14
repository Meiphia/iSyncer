import Foundation

struct LibraryRelink: Identifiable, Sendable {
    var id: URL { destination }
    let source: URL
    let destination: URL
    let paths: Set<String>
    let missing: [String]

    var matched: Int { paths.count - missing.count }

    static func inspect(source: URL, destination: URL, paths: Set<String>) throws -> Self {
        guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let missing = paths.filter {
            (try? destination.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true
        }
        return Self(source: source, destination: destination, paths: paths, missing: missing.sorted())
    }
}
