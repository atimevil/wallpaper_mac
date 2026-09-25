import Foundation

/// `type: video`인 항목의 실제 파일이 macOS AVFoundation으로 열리지 않는
/// 컨테이너인지 미리 가려낸다.
///
/// **실측 근거 (2026-09-06, macOS 26 / Darwin 25, arm64):**
/// `AVURLAsset(url:).load(.isPlayable)`으로 직접 확인했다.
/// - `.webm`(VP8, VP9 둘 다) — `isPlayable == false`, 트랙 로드 자체가
///   `Cannot Open` / `This media format is not supported`로 실패한다.
/// - `.mkv` — 안에 든 코덱이 **AVFoundation이 정상적으로 여는 H.264라도**
///   똑같이 열리지 않는다. 즉 실패 원인은 코덱이 아니라 컨테이너(EBML/
///   Matroska 디먹서 부재) 자체다.
/// - `.mp4`(H.264) — 대조군으로 `isPlayable == true`, 정상 재생된다.
///
/// 즉 이 머신에는 WebM/Matroska 디먹서가 전혀 없다. VideoToolbox가 VP9/AV1
/// 하드웨어 디코드를 지원하는 것과는 별개로, AVFoundation이 그 프레임을
/// 컨테이너에서 꺼내 넘겨줄 방법이 없으면 소용없다. 코덱을 더 세밀히 검사해도
/// (예: AV1) 결론은 같다 — 이 두 컨테이너는 통째로 열리지 않는다.
///
/// 그래서 여기서는 "AVFoundation이 열 수 있는 컨테이너인가"만 판정한다.
/// 실제로 열어보는 것(AVAsset 비동기 로드)은 AVFoundation을 요구하므로
/// WallflowKit이 아니라 WallflowApp 쪽 책임이고, 여기서는 확장자 자체가
/// 이미 알려진 미지원 컨테이너인지만 빠르게 걸러낸다.
public enum UnsupportedVideoFormat {
    /// 확장자만으로 이미 열 수 없다고 확신할 수 있는 컨테이너들.
    /// macOS AVFoundation은 WebM(VP8/VP9/Opus)과 Matroska(MKV)를 컨테이너
    /// 단계에서부터 지원하지 않는다 — 안의 코덱이 H.264라도 마찬가지다.
    private static let knownUnsupportedContainers: [String: String] = [
        "webm": "WebM",
        "mkv": "Matroska(MKV)",
    ]

    /// CodecID 문자열(EBML 안에 ASCII로 그대로 박혀 있다)로 알아낼 수 있는
    /// 코덱 이름. 파일 앞부분을 훑어 가장 먼저 걸리는 것을 보고한다.
    /// 못 찾아도 컨테이너 이름만으로 이유를 만들 수 있으니 실패해도 무방하다.
    private static let codecMarkers: [(marker: String, name: String)] = [
        ("V_VP9", "VP9"),
        ("V_VP8", "VP8"),
        ("V_AV1", "AV1"),
        ("V_MPEG4/ISO/AVC", "H.264"),
        ("V_MPEGH/ISO/HEVC", "HEVC"),
    ]

    /// 확장자만으로 컨테이너 문제인지만 빠르게 본다. 코덱까지 들여다보지
    /// 않으므로 파일을 열지 않는다 — 라이브러리를 스캔하거나 배경화면을 붙일
    /// 때마다 불러도 싸다. 자세한 이유 문자열이 필요하면 reason(forFile:)을
    /// 쓴다(코덱까지 훑어 더 느리다).
    public static func isKnownUnsupportedContainer(_ url: URL) -> Bool {
        knownUnsupportedContainers[url.pathExtension.lowercased()] != nil
    }

    /// 이 URL이 확장자만으로 이미 미지원 컨테이너라고 판정되면, 사용자에게
    /// 보여줄 한국어 이유를 만든다. 열 수 있어 보이면(또는 판단할 수 없으면)
    /// nil을 준다 — 실제 재생 가능 여부의 최종 판정은 AVFoundation이 한다.
    public static func reason(forFile url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard let container = knownUnsupportedContainers[ext] else { return nil }

        let codec = sniffCodec(at: url)
        let codecPart = codec.map { "(코덱: \($0)) " } ?? ""
        return "\(container) \(codecPart)".trimmingCharacters(in: .whitespaces)
            + " 컨테이너는 macOS의 AVFoundation이 디코딩하지 못한다"
            + " (코덱이 아니라 컨테이너 자체가 문제다 — H.264를 넣어도 안 열린다)."
            + " mp4/mov 컨테이너(H.264 또는 HEVC)로 다시 인코딩해야 재생할 수 있다."
    }

    /// 파일 앞부분에서 Matroska/WebM CodecID 문자열을 찾아 코덱 이름을 추정한다.
    /// EBML을 제대로 파싱하지 않고 알려진 ASCII 마커를 문자열 검색만 한다 —
    /// CodecID 엘리먼트는 헤더 근처에 평문 ASCII로 들어 있어 이 정도로 충분하고,
    /// 실패해도 컨테이너 이름만으로 이유는 만들 수 있으므로 굳이 EBML 파서를
    /// 새로 들이지 않는다.
    private static func sniffCodec(at url: URL) -> String? {
        // 코덱 마커는 보통 파일 앞머리 트랙 정보 안에 있다. 너무 크게 읽지
        // 않는다 — 영상 하나가 수백 MB일 수 있다.
        let sampleSize = 256 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sampleSize), !data.isEmpty else { return nil }

        for (marker, name) in codecMarkers {
            if data.range(of: Data(marker.utf8)) != nil {
                return name
            }
        }
        return nil
    }
}
