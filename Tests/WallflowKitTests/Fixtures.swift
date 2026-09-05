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

/// flags & 4면 밉맵 뒤에 TEXS 섹션이 붙는다.
func spriteSheetV2(frameCount: Int32) -> Data {
    nullTerminated("TEXS0002") + le32(frameCount) + Data(count: Int(frameCount) * 32)
}

func spriteSheetV3(frameCount: Int32, grid: (Int32, Int32)) -> Data {
    nullTerminated("TEXS0003") + le32(frameCount) + le32(grid.0) + le32(grid.1)
        + Data(count: Int(frameCount) * 32)
}
