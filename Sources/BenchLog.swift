import Foundation

/// CSV/JSONL logger writing into Documents/BenchLogs so files are reachable
/// from the Files app and iTunes File Sharing on Windows.
final class BenchLog {
    static let shared = BenchLog()

    let root: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("BenchLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Creates a new CSV file with the given header and returns a writer.
    func newCSV(test: String, header: String) -> CSVWriter {
        let stamp = Self.stampFormatter.string(from: Date())
        let url = root.appendingPathComponent("\(stamp)_\(test).csv")
        return CSVWriter(url: url, header: header)
    }

    func listFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteAll() {
        for url in listFiles() { try? FileManager.default.removeItem(at: url) }
    }
}

final class CSVWriter {
    let url: URL
    private var handle: FileHandle?

    init(url: URL, header: String) {
        self.url = url
        let data = (header + "\n").data(using: .utf8)!
        FileManager.default.createFile(atPath: url.path, contents: data)
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    func row(_ fields: [String]) {
        let line = fields.map { field in
            field.contains(",") || field.contains("\"")
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : field
        }.joined(separator: ",") + "\n"
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}
