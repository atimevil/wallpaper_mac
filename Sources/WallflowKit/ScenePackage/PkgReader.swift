import Foundation

public enum PkgError: Error, Equatable {
    case truncated
    case badVersionString
    case entryOutOfBounds(String)
    case missingEntry(String)
}

/// Wallpaper Engine의 scene.pkg 컨테이너를 읽는다.
///
/// 레이아웃 (실물 파일에서 확인, 잔여 바이트 0):
///   int32 길이 + "PKGV00NN"
///   int32 엔트리 수
///   엔트리마다: int32 길이 + 이름, int32 오프셋, int32 길이
///   그 뒤부터 블롭. 오프셋은 블롭 시작 기준 상대값.
public struct PkgReader: Sendable {
    private let data: Data
    private let entries: [String: Range<Int>]

    public let version: String

    public var names: [String] { Array(entries.keys) }

    public init(data: Data) throws {
        self.data = data
        var cursor = Cursor(data)

        version = try cursor.readString()
        guard version.hasPrefix("PKGV") else { throw PkgError.badVersionString }

        let count = try cursor.readInt32()
        guard count >= 0 else { throw PkgError.truncated }

        var raw: [(String, Int, Int)] = []
        raw.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try cursor.readString()
            let offset = Int(try cursor.readInt32())
            let length = Int(try cursor.readInt32())
            raw.append((name, offset, length))
        }

        // 남은 전부가 블롭이다.
        let base = cursor.offset
        var table: [String: Range<Int>] = [:]
        for (name, offset, length) in raw {
            guard offset >= 0, length >= 0 else { throw PkgError.entryOutOfBounds(name) }
            let start = base + offset
            let end = start + length
            guard start <= data.count, end <= data.count, start <= end else {
                throw PkgError.entryOutOfBounds(name)
            }
            table[name] = start..<end
        }
        entries = table
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func data(for name: String) throws -> Data {
        guard let range = entries[name] else { throw PkgError.missingEntry(name) }
        // 호출자가 슬라이스를 넘기면 startIndex가 0이 아니다. 항상 기준을 더한다.
        let lower = data.startIndex + range.lowerBound
        let upper = data.startIndex + range.upperBound
        return data.subdata(in: lower..<upper)
    }
}

/// 범위를 벗어나면 크래시 대신 오류를 던지는 리틀엔디언 커서.
/// 손상된 배경화면 파일이 앱을 죽여서는 안 된다.
struct Cursor {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func readInt32() throws -> Int32 {
        guard offset + 4 <= data.count else { throw PkgError.truncated }
        defer { offset += 4 }
        let start = data.startIndex + offset
        return data[start..<(start + 4)].withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self).littleEndian
        }
    }

    mutating func readString() throws -> String {
        let length = Int(try readInt32())
        guard length >= 0, offset + length <= data.count else { throw PkgError.truncated }
        defer { offset += length }
        let start = data.startIndex + offset
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw PkgError.truncated }
        offset += count
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw PkgError.truncated }
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }
}
