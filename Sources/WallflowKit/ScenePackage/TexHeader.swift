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

/// 시트 프레임 한 장. rect는 원본 텍스처의 픽셀 좌표(좌상단 기준)다.
///
/// 실물 8개 — TEXS0003(격자 있음) 5개: 워크숍 3795096226 "Loading..."의
/// background.tex, Assets의 smoke2light·lightning3·sparks_sheet·splash_9;
/// TEXS0002(격자 없음) 3개: smoke3·lightning1·lightning2 — 로 필드 배치를
/// 확인했다: float32 리틀엔디언 8개 —
/// `[예약, 길이(초), x, y, 폭, ?, ?, 높이]`. 예약과 물음표 둘은 전부 0이었다 —
/// 의미를 모른다. TEXS0002 시트(파티클)는 duration이 전부 0이다 — 그쪽은
/// 재생 시간을 프레임 표가 아니라 파티클 나이로 정하기 때문으로 보인다.
public struct TexSpriteFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// 이 프레임을 보여주는 시간(초). 0 이하일 수 있다 — 고르는 쪽(`frame(atElapsed:)`)이
    /// 방어한다.
    public let duration: Double
}

/// flags & 4인 텍스처의 밉맵 뒤에 붙는 프레임 표.
/// M4는 프레임 내용을 쓰지 않았다 — 존재를 알아야 잔여 바이트가 남지 않고,
/// 파티클이 스프라이트 시트를 요구할 때 건너뛸 근거가 된다. Task 5부터는
/// 이미지 레이어도 이 표로 애니메이션 프레임을 고른다.
public struct TexSpriteSheet: Equatable, Sendable {
    public let frameCount: Int
    /// TEXS0003에만 있다.
    public let gridWidth: Int?
    public let gridHeight: Int?
    /// 프레임 표. `frameCount`와 길이가 같다.
    public let frames: [TexSpriteFrame]

    /// 누적 재생 시간으로 프레임 하나를 고른다. 전체 길이(모든 duration의 합)를
    /// 채우면 되감는다(반복). 0 길이 프레임은 창이 없어 절대 고를 수 없다 —
    /// 음수 duration도 같은 값으로 죈다.
    ///
    /// duration 합이 0 이하면(전부 0이거나 프레임이 없으면) 반복할 길이가 없다.
    /// 나누기 0이나 무한 루프 대신 첫 프레임에서 멈춘다 — TEXS0002 파티클
    /// 시트가 실제로 이 모양이다(duration을 안 쓰고 파티클 나이로 고른다).
    public func frame(atElapsed elapsed: Double) -> TexSpriteFrame? {
        guard !frames.isEmpty else { return nil }
        let total = frames.reduce(0.0) { $0 + Swift.max(0, $1.duration) }
        guard total > 0, elapsed.isFinite, elapsed >= 0 else { return frames[0] }
        var t = elapsed.truncatingRemainder(dividingBy: total)
        for candidate in frames {
            let d = Swift.max(0, candidate.duration)
            if t < d { return candidate }
            t -= d
        }
        // 부동소수 오차로 마지막 칸 문턱을 살짝 넘을 때만 여기 닿는다.
        return frames.last
    }

    /// n번째 칸이 시작되는 누적 재생 시간(초).
    ///
    /// 스크립트(`thisLayer.getTextureAnimation().setFrame(n)`)가 특정 칸을
    /// 못박았을 때, 재생 위치(`elapsed`)를 이 값으로 옮기면 `frame(atElapsed:)`가
    /// 정확히 n번 칸을 돌려주고, 그 뒤 다시 play()해도 n번 칸부터 자연스럽게
    /// 이어진다 — 통째로 되감기지 않는다.
    ///
    /// n은 count로 감싼다(wrap). 실물 스크립트가 음수나 범위 밖 값을 줄 근거는
    /// 없지만, 사용자 파일에서 온 frameCount와 합쳐지면 방어가 필요하다 —
    /// Swift의 `%`는 피제수가 음수면 음수를 돌려주므로 두 번 감싸 항상
    /// `[0, count)`로 만든다. 프레임이 없으면 0.
    public func startTime(ofFrame n: Int) -> Double {
        guard !frames.isEmpty else { return 0 }
        let count = frames.count
        let index = ((n % count) + count) % count
        var t = 0.0
        for i in 0..<index { t += Swift.max(0, frames[i].duration) }
        return t
    }
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
        let hasGrid: Bool
        switch magic {
        case "TEXS0002": hasGrid = false
        case "TEXS0003": hasGrid = true
        default: throw TexError.unsupportedContainer(magic)
        }
        let frameCount = Int(try cursor.readInt32())
        var gridWidth: Int?
        var gridHeight: Int?
        if hasGrid {
            gridWidth = Int(try cursor.readInt32())
            gridHeight = Int(try cursor.readInt32())
        }
        // frameCount는 파일에서 온 값이다. 남은 바이트로 상한이 정해진다.
        // (오버플로우 걱정 없이 나눗셈으로 상한을 잡는다 — 곱셈보다 먼저 해야 안전하다.)
        let remaining = data.count - cursor.offset
        guard frameCount >= 0, frameCount <= remaining / bytesPerFrame else {
            throw TexError.truncated
        }
        // 프레임 하나(32바이트)는 float32 리틀엔디언 8개다:
        // [예약, 길이(초), x, y, 폭, 미상, 미상, 높이]. TexSpriteFrame 문서 참고.
        var frames: [TexSpriteFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            _ = try cursor.readFloat32()                  // 예약. 실물 8종 전부 0.
            let duration = Double(try cursor.readFloat32())
            let x = Double(try cursor.readFloat32())
            let y = Double(try cursor.readFloat32())
            let width = Double(try cursor.readFloat32())
            _ = try cursor.readFloat32()                  // 미상. 실물 8종 전부 0.
            _ = try cursor.readFloat32()                  // 미상. 실물 8종 전부 0.
            let height = Double(try cursor.readFloat32())
            frames.append(TexSpriteFrame(x: x, y: y, width: width, height: height, duration: duration))
        }

        return TexSpriteSheet(
            frameCount: frameCount, gridWidth: gridWidth, gridHeight: gridHeight, frames: frames)
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

    /// 프레임 표의 각 필드는 IEEE754 float32 리틀엔디언이다. readInt32의 비트
    /// 패턴을 그대로 Float로 옮긴다 — 새 엔디언 처리를 만들지 않는다.
    mutating func readFloat32() throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try readInt32()))
    }
}
