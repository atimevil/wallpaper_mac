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
