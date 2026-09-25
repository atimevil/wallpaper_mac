import Foundation

func le32(_ v: Int32) -> Data {
    var x = v
    return withUnsafeBytes(of: &x) { Data($0) }
}

/// 길이 접두 문자열. .pkg가 쓰는 형식이다.
func lengthPrefixed(_ s: String) -> Data {
    le32(Int32(s.utf8.count)) + Data(s.utf8)
}

/// 실물과 같은 레이아웃으로 최소 .pkg를 만든다.
func buildPkg(version: String, entries: [(String, Data)]) -> Data {
    var header = lengthPrefixed(version)
    header += le32(Int32(entries.count))
    var offset: Int32 = 0
    var blobs = Data()
    for (name, payload) in entries {
        header += lengthPrefixed(name)
        header += le32(offset)
        header += le32(Int32(payload.count))
        offset += Int32(payload.count)
        blobs += payload
    }
    return header + blobs
}

/// 널 종료 문자열. .tex가 쓰는 형식이다 (.pkg의 길이 접두와 다르다).
func nullTerminated(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

/// 실물 레이아웃대로 .tex를 합성한다.
/// mips는 (width, height, isLZ4, decompressedSize, payload).
func buildTex(
    container: String = "TEXB0004",
    format: Int32 = 0,
    flags: Int32 = 2,
    freeImageFormat: Int32 = 2,
    size: (Int32, Int32) = (2048, 1164),
    mips: [(Int32, Int32, Int32, Int32, Data)]
) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)                       // color
    d += nullTerminated(container)
    d += le32(1)                       // imageCount
    d += le32(freeImageFormat)
    if container == "TEXB0004" { d += le32(0) }
    d += le32(Int32(mips.count))
    for (w, h, lz4, decomp, payload) in mips {
        d += le32(w) + le32(h) + le32(lz4) + le32(decomp) + le32(Int32(payload.count))
        d += payload
    }
    return d
}

/// TEXB0001은 freeImageFormat도 LZ4 필드도 없다. 항상 원시 픽셀이다.
func buildTexV1(format: Int32 = 0, flags: Int32 = 0,
                size: (Int32, Int32) = (32, 32),
                mips: [(Int32, Int32, Data)]) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)
    d += nullTerminated("TEXB0001")
    d += le32(1) + le32(Int32(mips.count))
    for (w, h, payload) in mips {
        d += le32(w) + le32(h) + le32(Int32(payload.count)) + payload
    }
    return d
}

/// TEXB0002는 TEXB0003에서 freeImageFormat만 빠진 형태다.
func buildTexV2(format: Int32 = 0, flags: Int32 = 0,
                size: (Int32, Int32) = (32, 32),
                mips: [(Int32, Int32, Int32, Int32, Data)]) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)
    d += nullTerminated("TEXB0002")
    d += le32(1) + le32(Int32(mips.count))
    for (w, h, lz4, decomp, payload) in mips {
        d += le32(w) + le32(h) + le32(lz4) + le32(decomp) + le32(Int32(payload.count))
        d += payload
    }
    return d
}

/// flags & 4면 밉맵 뒤에 TEXS 섹션이 붙는다. frames를 주면 그 32바이트짜리
/// 프레임들을 그대로 쓰고, 안 주면 예전처럼 0으로 채운다(내용을 안 보는 시험용).
func spriteSheetV2(frameCount: Int32, frames: [Data]? = nil) -> Data {
    nullTerminated("TEXS0002") + le32(frameCount)
        + (frames.map { Data($0.joined()) } ?? Data(count: Int(frameCount) * 32))
}

func spriteSheetV3(frameCount: Int32, grid: (Int32, Int32), frames: [Data]? = nil) -> Data {
    nullTerminated("TEXS0003") + le32(frameCount) + le32(grid.0) + le32(grid.1)
        + (frames.map { Data($0.joined()) } ?? Data(count: Int(frameCount) * 32))
}

/// 프레임 표 한 칸(32바이트). 실물 8종(TexSpriteFrame 문서에 적은 background.tex·
/// smoke2light·smoke3·lightning1~3·sparks_sheet·splash_9)으로 확인한 배치:
/// float32 리틀엔디언 8개 = [예약, 길이(초), x, y, 폭, 미상, 미상, 높이].
/// 예약과 미상 둘은 실물 전부 0이었다.
func spriteFrame(x: Float, y: Float, width: Float, height: Float, duration: Float) -> Data {
    [Float(0), duration, x, y, width, Float(0), Float(0), height]
        .reduce(into: Data()) { bytes, value in
            var v = value
            bytes += withUnsafeBytes(of: &v) { Data($0) }
        }
}
