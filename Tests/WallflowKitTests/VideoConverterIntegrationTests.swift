import XCTest
@testable import WallflowKit

/// 실제 ffmpeg 바이너리를 돌려 webm→mp4 변환 전체 경로를 확인한다.
///
/// WALLFLOW_TEST_FFMPEG가 없으면 건너뛴다 — CorpusCoverageProbe가
/// WALLFLOW_TEST_ASSETS로 하듯, 이 저장소는 "무거운·환경 의존적인" 테스트를
/// 기본 테스트 실행에 끼워 넣지 않고 환경변수로 옵트인시키는 관례를 쓴다.
/// 기본 `swift test`는 서브프로세스를 실제로 띄우지 않는다.
final class VideoConverterIntegrationTests: XCTestCase {
    func testConvertsRealWebmWithFfmpeg() throws {
        guard ProcessInfo.processInfo.environment["WALLFLOW_TEST_FFMPEG"] != nil else {
            throw XCTSkip("WALLFLOW_TEST_FFMPEG 미설정 — 실제 ffmpeg 통합 테스트를 건너뛴다")
        }
        guard let ffmpeg = VideoConverter.locateExecutable() else {
            throw XCTSkip("이 머신에서 ffmpeg를 찾지 못했다")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-videoconverter-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 아주 작은 webm을 실제로 만든다. testsrc는 ffmpeg 내장 패턴 생성기라
        // 입력 파일 없이도 소스를 만들 수 있다(브리프가 준 그 명령 그대로).
        let source = root.appendingPathComponent("tiny.webm")
        let generate = Process()
        generate.executableURL = ffmpeg
        generate.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=10", source.path,
        ]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        generate.waitUntilExit()
        guard generate.terminationStatus == 0, FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("이 ffmpeg가 webm 인코더를 지원하지 않는다")
        }

        // 1) VideoConverter.convert(): 결정(탐색·인자·캐시 키)과 실행을 함께 확인.
        let converter = VideoConverter(
            executable: ffmpeg, cacheDirectory: root.appendingPathComponent("cache"))
        let output = try converter.convert(source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let outAttrs = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertGreaterThan((outAttrs[.size] as? Int64) ?? 0, 0)

        // 2) Kit이 짠 인자로 Process를 직접 부르는 경로도 확인한다 — 브리프가
        // 명시한 "Kit-planned arguments using Foundation Process" 통합 경로.
        let manualOutput = root.appendingPathComponent("manual.mp4")
        let manual = Process()
        manual.executableURL = ffmpeg
        manual.arguments = VideoConverter.arguments(input: source, output: manualOutput)
        manual.standardOutput = FileHandle.nullDevice
        manual.standardError = FileHandle.nullDevice
        try manual.run()
        manual.waitUntilExit()
        XCTAssertEqual(manual.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manualOutput.path))
    }
}
