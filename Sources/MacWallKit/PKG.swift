import Foundation

public enum FormatError: Error, Equatable {
    case truncated
    case badMagic(String)
    case unsupported(String)
}

/// Little-endian cursor over a byte buffer; every read is bounds-checked.
struct ByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data) { self.data = data; pos = data.startIndex }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, pos + n <= data.endIndex else { throw FormatError.truncated }
        defer { pos += n }
        return data[pos..<pos + n]
    }

    mutating func u32() throws -> UInt32 {
        try bytes(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// uint32 length followed by that many bytes.
    mutating func lengthPrefixedString() throws -> String {
        String(decoding: try bytes(Int(try u32())), as: UTF8.self)
    }

    /// NUL-terminated string (terminator consumed).
    mutating func cString(max: Int = 32) throws -> String {
        var out = [UInt8]()
        while true {
            let b = try bytes(1).first!
            if b == 0 { break }
            out.append(b)
            if out.count > max { throw FormatError.truncated }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Wallpaper Engine `scene.pkg`: "PKGVxxxx" header, a file table of (name, offset, size),
/// then the file bodies; offsets are relative to the end of the table.
public struct PKGArchive {
    public let version: String
    public let names: [String]
    private let entries: [String: Range<Int>]
    private let data: Data

    public init(data: Data) throws {
        var r = ByteReader(data)
        version = try r.lengthPrefixedString()
        guard version.hasPrefix("PKGV") else { throw FormatError.badMagic(String(version.prefix(8))) }
        let count = Int(try r.u32())
        var table: [(String, Int, Int)] = []
        for _ in 0..<count {
            table.append((try r.lengthPrefixedString(), Int(try r.u32()), Int(try r.u32())))
        }
        let base = r.pos
        var entries: [String: Range<Int>] = [:]
        for (name, offset, size) in table {
            let range = base + offset..<base + offset + size
            guard range.upperBound <= data.endIndex else { throw FormatError.truncated }
            entries[name] = range
        }
        names = table.map(\.0)
        self.entries = entries
        self.data = data
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    public subscript(name: String) -> Data? { entries[name].map { data[$0] } }
}
