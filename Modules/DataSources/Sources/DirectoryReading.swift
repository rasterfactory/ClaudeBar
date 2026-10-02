import Foundation

public struct DirectoryRecord: Sendable, Equatable, Codable {
    public let name: String
    public let text: String
    public init(name: String, text: String) { self.name = name; self.text = text }
}

/// File I/O is separate from the definition's pure mapping, and replaceable in tests.
public protocol DirectoryReading: Sendable {
    func read(_ root: URL, file: String, pattern: String) throws -> [DirectoryRecord]
}

public struct SystemDirectoryReader: DirectoryReading {
    public init() {}
    public func read(_ root: URL, file: String, pattern: String) throws -> [DirectoryRecord] {
        guard file == URL(fileURLWithPath: file).lastPathComponent, file != ".", file != "..", !file.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { entry in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &directory), directory.boolValue else { return nil }
            let name = entry.lastPathComponent
            guard regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil,
                  let data = try? Data(contentsOf: entry.appendingPathComponent(file)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return DirectoryRecord(name: name, text: text)
        }
    }
}
