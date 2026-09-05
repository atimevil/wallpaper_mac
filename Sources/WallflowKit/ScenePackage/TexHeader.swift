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

/// flags & 4인 텍스처의 밉맵 뒤에 붙는 프레임 표.
/// M4는 프레임 내용을 쓰지 않는다 — 존재를 알아야 잔여 바이트가 남지 않고,
/// 파티클이 스프라이트 시트를 요구할 때 건너뛸 근거가 된다.
public struct TexSpriteSheet: Equatable, Sendable {
    public let frameCount: Int
    /// TEXS0003에만 있다.
    public let gridWidth: Int?
    public let gridHeight: Int?
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
    /// DXT5(BC3). 4x4 블록 하나가 16바이트다.
    ///
    /// DXT3(BC2)도 블록 크기가 같아 바이트 수로는 구분되지 않는다. 실물
    /// `flatnormal.tex`의 알파 블록이 `[127, 132, 0,0,0,0,0,0]`이고
    /// `sphere.tex`가 `[0, 255, 73,146,36,...]`인데, 이건 BC3의
    /// `[끝점 a0, 끝점 a1, 3비트 인덱스 6바이트]` 구조다. BC2로 읽으면
    /// 둘 다 의미 없는 잡음이 된다. 그래서 BC3으로 확정했다.
    case dxt5 = 4
    /// DXT1(BC1). 4x4 블록 하나가 8바이트다. 알파가 없거나 1비트다.
    /// 실물 `absbg.tex`(2560x1728)의 선언 크기가 정확히 8바이트/블록이다.
    case dxt1 = 7
    /// 두 채널. 실물에서 light_shafts처럼 흑백+알파 파티클 텍스처가 쓴다.
    case rg88 = 8
    /// 단일 채널. 마스크에 쓰인다.
    case r8 = 9

    /// 블록 압축 포맷인지. 이 경우 픽셀 단위 산술이 성립하지 않는다.
    public var isBlockCompressed: Bool { bytesPerBlock > 0 }

    /// 4x4 블록 하나가 차지하는 바이트. 블록 압축이 아니면 0이다.
    public var bytesPerBlock: Int {
        switch self {
        case .dxt1: return 8
        case .dxt5: return 16
        case .rgba8888, .rg88, .r8: return 0
        }
    }

    /// 픽셀 하나가 차지하는 바이트. 블록 압축이 아닌 포맷에만 의미가 있다.
    public var bytesPerPixel: Int {
        switch self {
        case .rgba8888: return 4
        case .rg88: return 2
        case .r8: return 1
        case .dxt5, .dxt1: return 0
        }
    }

    /// 이 치수의 이미지 한 장이 차지하는 바이트.
    /// 블록 압축은 4x4 블록 단위라 픽셀 곱셈으로는 못 구한다.
    /// 파일에서 온 치수를 곱하므로 오버플로우를 트랩이 아니라 nil로 돌려준다.
    public func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        if isBlockCompressed {
            // (width + 3)이 Int.max 근처에서 트랩한다. 치수는 파일에서 오므로
            // 더하기 전에 막는다. 나눈 뒤 올림하면 덧셈 자체가 필요 없다.
            let blocksWide = width / 4 + (width % 4 == 0 ? 0 : 1)
            let blocksHigh = height / 4 + (height % 4 == 0 ? 0 : 1)
            let (blocks, overflow) = blocksWide.multipliedReportingOverflow(by: blocksHigh)
            guard !overflow else { return nil }
            let (total, overflow2) = blocks.multipliedReportingOverflow(by: bytesPerBlock)
            return overflow2 ? nil : total
        }
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return nil }
        let (total, overflow2) = area.multipliedReportingOverflow(by: bytesPerPixel)
        return overflow2 ? nil : total
    }

    /// GPU에 올릴 때 한 줄이 차지하는 바이트. 블록 압축은 블록 줄 단위다.
    public func bytesPerRow(width: Int) -> Int {
        guard isBlockCompressed else { return width * bytesPerPixel }
        return (width / 4 + (width % 4 == 0 ? 0 : 1)) * bytesPerBlock
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
    /// flags의 이 비트가 서면 밉맵 뒤에 TEXS 스프라이트 시트가 붙는다.
    static let spriteSheetFlag: Int32 = 4

    /// 애플 실리콘의 Metal maxTexture2DDimension. WallflowKit은 Metal을 import하지
    /// 않으므로 이 값을 여기서 물어볼 수 없어 상수로 못박는다 — 이보다 큰 차원은
    /// 어차피 Metal 텍스처가 될 수 없다.
    /// TexDecoder의 세 디코드 분기(rawPixels, jpeg/png) 모두 이 상한을 적용해야
    /// "16384를 넘지 않는다"가 실제로 전역 불변조건이 된다 — 한 분기만 지켜서는
    /// 나머지 분기로 들어오는 압축 폭탄을 막지 못한다.
    public static let maxTextureDimension = 16384

    /// 프레임 하나는 32바이트다(실물에서 확인, 잔여 0).
    private static let bytesPerFrame = 32

    public let version: String
    public let format: Int32
    public let flags: Int32
    public let textureWidth: Int
    public let textureHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let freeImageFormat: Int32
    public let mipmaps: [TexMipmap]
    public let spriteSheet: TexSpriteSheet?
    /// 원본 데이터에서 파싱된 바이트 수. 파일이 완전히 소비되는지 검증할 때 쓴다.
    public let consumedBytes: Int

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
        let hasFreeImageFormat: Bool
        let hasExtraField: Bool
        let hasCompressionFields: Bool
        switch container {
        case "TEXB0001":
            // 가장 오래된 형태. freeImageFormat도 LZ4 필드도 없고 항상 원시 픽셀이다.
            hasFreeImageFormat = false; hasExtraField = false; hasCompressionFields = false
        case "TEXB0002":
            hasFreeImageFormat = false; hasExtraField = false; hasCompressionFields = true
        case "TEXB0003":
            hasFreeImageFormat = true;  hasExtraField = false; hasCompressionFields = true
        case "TEXB0004":
            hasFreeImageFormat = true;  hasExtraField = true;  hasCompressionFields = true
        default:
            throw TexError.unsupportedContainer(container)
        }

        _ = try cursor.readInt32()          // imageCount. 실물은 항상 1이었다.
        let freeImageFormat = hasFreeImageFormat ? try cursor.readInt32() : -1
        if hasExtraField { _ = try cursor.readInt32() }
        let mipCount = try cursor.readInt32()
        guard mipCount > 0 else { throw TexError.noMipmaps }

        // Bound mipCount: each mipmap is at least 12 bytes if no compression fields (w, h, size),
        // or 20 bytes with compression fields (w, h, lz4, decompressed, size)
        let bytesPerMip = hasCompressionFields ? 20 : 12
        let remainingBytes = data.count - cursor.offset
        let maxMipmaps = remainingBytes / bytesPerMip
        guard Int(mipCount) <= maxMipmaps else { throw TexError.truncated }

        var mipmaps: [TexMipmap] = []
        mipmaps.reserveCapacity(Int(mipCount))
        for _ in 0..<mipCount {
            let w = Int(try cursor.readInt32())
            let h = Int(try cursor.readInt32())
            let lz4: Int32
            let decompressed: Int
            if hasCompressionFields {
                lz4 = try cursor.readInt32()
                decompressed = Int(try cursor.readInt32())
            } else {
                lz4 = 0
                decompressed = 0
            }
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

        /// flags 비트 4가 서면 밉맵 뒤에 TEXS 섹션이 붙는다.
        /// 이 섹션을 못 읽어도 텍스처 자체는 쓸 수 있으므로 실패시키지 않는다 —
        /// 단, 프레임 수는 파일에서 온 값이라 남은 바이트로 상한을 검사한다.
        var spriteSheet: TexSpriteSheet?
        if flags & spriteSheetFlag != 0 {
            spriteSheet = try? parseSpriteSheet(&cursor, in: data)
        }

        return TexHeader(
            version: version, format: format, flags: flags,
            textureWidth: texW, textureHeight: texH,
            imageWidth: imgW, imageHeight: imgH,
            freeImageFormat: freeImageFormat, mipmaps: mipmaps,
            spriteSheet: spriteSheet, consumedBytes: cursor.offset
        )
    }

    private static func parseSpriteSheet(
        _ cursor: inout Cursor, in data: Data
    ) throws -> TexSpriteSheet {
        let magic = try cursor.readCString()
        let grid: (Int, Int)?
        switch magic {
        case "TEXS0002": grid = nil
        case "TEXS0003": grid = (0, 0)          // 아래에서 실제 값을 읽는다
        default: throw TexError.unsupportedContainer(magic)
        }
        let frameCount = Int(try cursor.readInt32())
        var width: Int?
        var height: Int?
        if grid != nil {
            width = Int(try cursor.readInt32())
            height = Int(try cursor.readInt32())
        }
        // frameCount는 파일에서 온 값이다. 남은 바이트로 상한이 정해진다.
        let remaining = data.count - cursor.offset
        guard frameCount >= 0, frameCount <= remaining / bytesPerFrame else {
            throw TexError.truncated
        }
        // 프레임 데이터 테이블을 건너뛴다. 오버플로우가 발생하면 truncated를 던진다.
        let (frameDataSize, multipliedOverflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
        guard !multipliedOverflow else { throw TexError.truncated }
        try cursor.skip(frameDataSize)

        return TexSpriteSheet(frameCount: frameCount, gridWidth: width, gridHeight: height)
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
