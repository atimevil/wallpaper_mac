import XCTest
@testable import WallflowKit

/// AVFoundation이 실제로 WebM/MKV를 못 여는 것을 macOS 26/Darwin 25에서
/// `AVURLAsset.load(.isPlayable)`로 직접 확인했다(스크래치 스크립트로 실측,
/// 근거는 UnsupportedVideoFormat.swift 문서 주석 참고). 이 테스트는 그 실측을
/// 바탕으로 만든 확장자 판정 로직만 검증한다 — AVFoundation을 여기서 다시
/// 부르지는 않는다(WallflowKit은 AVFoundation을 import하지 않는다).
final class UnsupportedVideoFormatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-video-format-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, containing bytes: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testMp4IsNotFlagged() throws {
        let url = try write("bg.mp4", containing: Data("not a real mp4 but extension is fine".utf8))
        XCTAssertNil(UnsupportedVideoFormat.reason(forFile: url))
    }

    func testMovIsNotFlagged() throws {
        let url = try write("bg.mov")
        XCTAssertNil(UnsupportedVideoFormat.reason(forFile: url))
    }

    func testWebmIsFlagged() throws {
        let url = try write("bg.webm")
        let reason = UnsupportedVideoFormat.reason(forFile: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("WebM"), "컨테이너 이름이 이유에 있어야 한다: \(reason!)")
    }

    func testMkvIsFlaggedRegardlessOfInnerCodec() throws {
        // 실측: mkv는 안에 H.264가 들어 있어도 열리지 않는다(컨테이너 자체 문제).
        let url = try write("bg.mkv")
        let reason = UnsupportedVideoFormat.reason(forFile: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Matroska") || reason!.contains("MKV"))
    }

    func testExtensionCaseIsIgnored() throws {
        let url = try write("bg.WEBM")
        XCTAssertNotNil(UnsupportedVideoFormat.reason(forFile: url))
    }

    func testCodecMarkerIsReportedWhenPresent() throws {
        // 실물 webm/mkv의 CodecID 엘리먼트는 ASCII로 "V_VP9" 같은 문자열을
        // 그대로 담고 있다. 진짜 EBML을 만들지 않고 그 마커만 앞부분에 심어서
        // 문자열 검색 경로를 검증한다.
        var bytes = Data([0x1A, 0x45, 0xDF, 0xA3]) // EBML 매직 넘버(장식용)
        bytes.append(Data("V_VP9".utf8))
        let url = try write("codec.webm", containing: bytes)
        let reason = UnsupportedVideoFormat.reason(forFile: url)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("VP9"), "코덱 이름이 이유에 있어야 한다: \(reason!)")
    }

    func testNoCodecMarkerStillProducesReason() throws {
        // 마커를 못 찾아도(진짜 EBML을 안 넣었으므로) 컨테이너 이름만으로도
        // 이유는 만들어져야 한다 — 사용자에게 아무 말도 안 하는 것보다는 낫다.
        let url = try write("bg.webm", containing: Data("garbage".utf8))
        XCTAssertNotNil(UnsupportedVideoFormat.reason(forFile: url))
    }

    func testUnrelatedExtensionIsNotFlagged() throws {
        for ext in ["avi", "gif", "html", "json", "png"] {
            let url = try write("bg.\(ext)")
            XCTAssertNil(UnsupportedVideoFormat.reason(forFile: url), "확장자 \(ext)는 검사 대상이 아니다")
        }
    }

    /// isKnownUnsupportedContainer는 reason(forFile:)과 달리 파일을 열지 않는다
    /// (코덱을 안 훑는다) — 존재하지 않는 경로로도 확장자만으로 판정돼야 한다.
    func testIsKnownUnsupportedContainerChecksExtensionOnlyWithoutReadingFile() {
        XCTAssertTrue(
            UnsupportedVideoFormat.isKnownUnsupportedContainer(
                URL(fileURLWithPath: "/does/not/exist.webm")))
        XCTAssertTrue(
            UnsupportedVideoFormat.isKnownUnsupportedContainer(
                URL(fileURLWithPath: "/does/not/exist.MKV")))
        XCTAssertFalse(
            UnsupportedVideoFormat.isKnownUnsupportedContainer(
                URL(fileURLWithPath: "/does/not/exist.mp4")))
    }
}
