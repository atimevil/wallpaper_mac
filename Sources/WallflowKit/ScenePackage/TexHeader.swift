import Foundation

public enum TexError: Error, Equatable {
    case badMagic(String)
    case unsupportedContainer(String)
    case truncated
    case noMipmaps
    // 아래 셋은 Task 3의 디코더가 쓴다. 태스크 간 파일 수정을 없애려고 여기서 함께 선언한다.
    case imageDecodeFailed
    case lz4Failed
    case unsupportedPixelFormat(Int32)
    /// width/height가 Metal의 maxTexture2DDimension(애플 실리콘 16384)을 넘는다.
    /// 산술 이전에 걸러야 한다. area가 오버플로우 없이 거대해질 수 있기 때문이다
    /// (예: r8 포맷에서 width=height=Int32.max).
    case dimensionsOutOfRange
}

/// .tex 안에 실제로 무엇이 들어 있는지.
public enum TexPayloadKind: Equatable, Sendable {
    case jpeg
    case png
    case rawPixels
    /// 데이터가 통째로 MP4(H.264) 파일이다. 실물 226MB 텍스처 두 개가 이 경우였다.
    case video
}

public enum TexPixelFormat: Int32, Sendable {
    case rgba8888 = 0
    /// 단일 채널. 마스크에 쓰인다.
    case r8 = 9

    /// 픽셀 하나가 차지하는 바이트. 디코더가 크기를 검증할 때 쓴다.
    public var bytesPerPixel: Int {
        switch self {
        case .rgba8888: return 4
        case .r8: return 1
        }
    }
}

public struct TexMipmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isLZ4: Bool
    public let decompressedSize: Int
    /// 원본 .tex 데이터 안에서 이 밉맵의 바이트 범위.
    public let range: Range<Int>
}

/// .tex 컨테이너의 헤더. 픽셀을 건드리지 않고 정체만 알아낸다.
///
/// 레이아웃 (실물 파일에서 확인, 잔여 바이트 0):
///   "TEXV0005\0" "TEXI0001\0"
///   int32 format, flags, texW, texH, imgW, imgH, color
///   "TEXB0003\0" 또는 "TEXB0004\0"
///   int32 imageCount, freeImageFormat, [0004면 하나 더], mipmapCount
///   밉맵마다: int32 w, h, isLZ4, decompressedSize, dataSize + 데이터
public struct TexHeader: Equatable, Sendable {
    /// flags의 이 비트가 서면 데이터가 MP4다.
    static let videoFlag: Int32 = 32

    /// 애플 실리콘의 Metal maxTexture2DDimension. WallflowKit은 Metal을 import하지
    /// 않으므로 이 값을 여기서 물어볼 수 없어 상수로 못박는다 — 이보다 큰 차원은
    /// 어차피 Metal 텍스처가 될 수 없다.
    /// TexDecoder의 세 디코드 분기(rawPixels, jpeg/png) 모두 이 상한을 적용해야
    /// "16384를 넘지 않는다"가 실제로 전역 불변조건이 된다 — 한 분기만 지켜서는
    /// 나머지 분기로 들어오는 압축 폭탄을 막지 못한다.
    public static let maxTextureDimension = 16384

    public let version: String
    public let format: Int32
    public let flags: Int32
    public let textureWidth: Int
    public let textureHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let freeImageFormat: Int32
    public let mipmaps: [TexMipmap]

    public var isVideo: Bool { flags & Self.videoFlag != 0 }

    public var pixelFormat: TexPixelFormat? { TexPixelFormat(rawValue: format) }

    public var kind: TexPayloadKind {
        if isVideo { return .video }
        switch freeImageFormat {
        case 2: return .jpeg
        case 13: return .png
        default: return .rawPixels
        }
    }

    public static func parse(_ data: Data) throws -> TexHeader {
        var cursor = Cursor(data)

        let version = try cursor.readCString()
        guard version.hasPrefix("TEXV") else { throw TexError.badMagic(version) }
        let imageMagic = try cursor.readCString()
        guard imageMagic.hasPrefix("TEXI") else { throw TexError.badMagic(imageMagic) }

        let format = try cursor.readInt32()
        let flags = try cursor.readInt32()
        let texW = Int(try cursor.readInt32())
        let texH = Int(try cursor.readInt32())
        let imgW = Int(try cursor.readInt32())
        let imgH = Int(try cursor.readInt32())
        _ = try cursor.readInt32()          // color. 쓰이지 않는다.

        let container = try cursor.readCString()
        let extraField: Bool
        switch container {
        case "TEXB0004": extraField = true
        case "TEXB0003": extraField = false
        default: throw TexError.unsupportedContainer(container)
        }

        _ = try cursor.readInt32()          // imageCount. 실물은 항상 1이었다.
        let freeImageFormat = try cursor.readInt32()
        if extraField { _ = try cursor.readInt32() }
        let mipCount = try cursor.readInt32()
        guard mipCount > 0 else { throw TexError.noMipmaps }

        // Bound mipCount: each mipmap is at least 20 bytes (5 int32s: w, h, lz4, decompressed, size)
        let remainingBytes = data.count - cursor.offset
        let maxMipmaps = remainingBytes / 20
        guard Int(mipCount) <= maxMipmaps else { throw TexError.truncated }

        var mipmaps: [TexMipmap] = []
        mipmaps.reserveCapacity(Int(mipCount))
        for _ in 0..<mipCount {
            let w = Int(try cursor.readInt32())
            let h = Int(try cursor.readInt32())
            let lz4 = try cursor.readInt32()
            let decompressed = Int(try cursor.readInt32())
            let size = Int(try cursor.readInt32())
            guard size >= 0, cursor.offset + size <= data.count else {
                throw TexError.truncated
            }
            let start = cursor.offset
            try cursor.skip(size)
            mipmaps.append(TexMipmap(
                width: w, height: h, isLZ4: lz4 == 1,
                decompressedSize: decompressed, range: start..<(start + size)
            ))
        }

        return TexHeader(
            version: version, format: format, flags: flags,
            textureWidth: texW, textureHeight: texH,
            imageWidth: imgW, imageHeight: imgH,
            freeImageFormat: freeImageFormat, mipmaps: mipmaps
        )
    }
}

extension Cursor {
    /// .tex는 길이 접두가 아니라 널 종료 문자열을 쓴다.
    mutating func readCString() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try readBytes(1)[0]
            if byte == 0 { break }
            bytes.append(byte)
            guard bytes.count < 64 else { throw TexError.badMagic(String(decoding: bytes, as: UTF8.self)) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
