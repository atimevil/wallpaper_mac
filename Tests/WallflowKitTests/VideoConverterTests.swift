import XCTest
@testable import WallflowKit

/// ffmpeg로 webm/mkv를 mp4로 바꾸는 "결정"들 — 탐색 순서, 캐시 키, 인자,
/// 캐시 축출 — 은 전부 순수 함수라 여기서 직접 검증한다. 실제 ffmpeg 실행은
/// VideoConverterIntegrationTests(환경변수로 게이트)에서 다룬다.
final class VideoConverterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-videoconverter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 분류: 컨테이너만 문제면 변환 대상

    func testWebmNeedsConversion() {
        XCTAssertTrue(VideoConverter.needsConversion(URL(fileURLWithPath: "/x/bg.webm")))
    }

    func testMkvNeedsConversion() {
        XCTAssertTrue(VideoConverter.needsConversion(URL(fileURLWithPath: "/x/bg.mkv")))
    }

    func testMp4DoesNotNeedConversion() {
        XCTAssertFalse(VideoConverter.needsConversion(URL(fileURLWithPath: "/x/bg.mp4")))
    }

    func testExtensionCaseIsIgnoredForClassification() {
        XCTAssertTrue(VideoConverter.needsConversion(URL(fileURLWithPath: "/x/bg.WEBM")))
    }

    // MARK: - ffmpeg 탐색 순서

    func testDefaultSearchPathsPreferHomebrewThenUsrLocal() {
        XCTAssertEqual(VideoConverter.defaultSearchPaths.map(\.path), [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ])
    }

    func testLocateExecutablePrefersFirstExistingSearchPath() {
        let found = VideoConverter.locateExecutable(
            searching: [
                URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            ],
            pathEnvironment: "/should/not/be/used",
            fileExists: { $0 == "/usr/local/bin/ffmpeg" || $0 == "/opt/homebrew/bin/ffmpeg" }
        )
        // 두 경로 다 있는 척해도 순서상 먼저 오는 것을 골라야 한다(brew 우선).
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/ffmpeg")
    }

    func testLocateExecutableFallsBackToPathWhenSearchPathsMissing() {
        // Finder에서 켠 앱은 로그인 셸의 PATH를 물려받지 않으므로, 표준 위치에
        // 없을 때만 PATH를 훑는다.
        let found = VideoConverter.locateExecutable(
            searching: [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")],
            pathEnvironment: "/a/bin:/b/bin",
            fileExists: { $0 == "/b/bin/ffmpeg" }
        )
        XCTAssertEqual(found?.path, "/b/bin/ffmpeg")
    }

    func testLocateExecutableReturnsNilWhenNowhereFound() {
        let found = VideoConverter.locateExecutable(
            searching: [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")],
            pathEnvironment: "/a/bin",
            fileExists: { _ in false }
        )
        XCTAssertNil(found)
    }

    func testLocateExecutableToleratesNilPathEnvironment() {
        let found = VideoConverter.locateExecutable(
            searching: [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")],
            pathEnvironment: nil,
            fileExists: { _ in false }
        )
        XCTAssertNil(found)
    }

    // MARK: - 캐시 키

    func testCacheKeyIsDeterministic() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VideoConverter.cacheKey(sourcePath: "/x/bg.webm", sizeBytes: 123, modifiedAt: date)
        let b = VideoConverter.cacheKey(sourcePath: "/x/bg.webm", sizeBytes: 123, modifiedAt: date)
        XCTAssertEqual(a, b)
    }

    func testCacheKeyChangesWithPath() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VideoConverter.cacheKey(sourcePath: "/x/a.webm", sizeBytes: 123, modifiedAt: date)
        let b = VideoConverter.cacheKey(sourcePath: "/x/b.webm", sizeBytes: 123, modifiedAt: date)
        XCTAssertNotEqual(a, b)
    }

    func testCacheKeyChangesWithSize() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VideoConverter.cacheKey(sourcePath: "/x/a.webm", sizeBytes: 123, modifiedAt: date)
        let b = VideoConverter.cacheKey(sourcePath: "/x/a.webm", sizeBytes: 124, modifiedAt: date)
        XCTAssertNotEqual(a, b)
    }

    func testCacheKeyChangesWithModifiedDate() {
        let a = VideoConverter.cacheKey(
            sourcePath: "/x/a.webm", sizeBytes: 123, modifiedAt: Date(timeIntervalSince1970: 1))
        let b = VideoConverter.cacheKey(
            sourcePath: "/x/a.webm", sizeBytes: 123, modifiedAt: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(a, b)
    }

    func testCacheFileURLLivesUnderCacheDirectoryWithMp4Extension() {
        let converter = VideoConverter(executable: nil, cacheDirectory: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = converter.cacheFileURL(sourcePath: "/x/bg.webm", sizeBytes: 1, modifiedAt: date)
        XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(url.pathExtension, "mp4")
    }

    // MARK: - ffmpeg 인자

    func testArgumentsShape() {
        let input = URL(fileURLWithPath: "/x/bg.webm")
        let output = URL(fileURLWithPath: "/y/out.mp4")
        XCTAssertEqual(VideoConverter.arguments(input: input, output: output), [
            "-y", "-nostdin", "-loglevel", "error",
            "-i", "/x/bg.webm",
            "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mp4",
            "/y/out.mp4",
        ])
    }

    // MARK: - 캐시 축출(LRU, 2GB 상한)

    func testFilesToEvictIsEmptyWhenUnderCap() {
        let files = [
            VideoConverter.CacheFile(url: URL(fileURLWithPath: "/c/a.mp4"), sizeBytes: 100, lastUsedAt: Date()),
        ]
        XCTAssertEqual(VideoConverter.filesToEvict(files, capBytes: 1000), [])
    }

    func testFilesToEvictRemovesOldestFirstUntilUnderCap() {
        let old = Date(timeIntervalSince1970: 1)
        let mid = Date(timeIntervalSince1970: 2)
        let new = Date(timeIntervalSince1970: 3)
        let files = [
            VideoConverter.CacheFile(url: URL(fileURLWithPath: "/c/new.mp4"), sizeBytes: 40, lastUsedAt: new),
            VideoConverter.CacheFile(url: URL(fileURLWithPath: "/c/old.mp4"), sizeBytes: 40, lastUsedAt: old),
            VideoConverter.CacheFile(url: URL(fileURLWithPath: "/c/mid.mp4"), sizeBytes: 40, lastUsedAt: mid),
        ]
        // 총합 120, 상한 50 → 70을 덜어내야 한다: old(40) + mid(40)면 충분하니 둘만 지운다.
        let evicted = VideoConverter.filesToEvict(files, capBytes: 50)
        XCTAssertEqual(evicted, [
            URL(fileURLWithPath: "/c/old.mp4"),
            URL(fileURLWithPath: "/c/mid.mp4"),
        ])
    }

    func testFilesToEvictNeverEvictsKeepEvenAloneOverCap() {
        let files = [
            VideoConverter.CacheFile(
                url: URL(fileURLWithPath: "/c/justmade.mp4"), sizeBytes: 5000, lastUsedAt: Date()),
        ]
        // keep 혼자서도 상한을 넘지만, 방금 만든 캐시를 스스로 지우면 다음에 또
        // 변환해야 하는 무한 루프가 된다 — keep은 절대 후보에 넣지 않는다.
        let evicted = VideoConverter.filesToEvict(
            files, capBytes: 1000, keep: [URL(fileURLWithPath: "/c/justmade.mp4")])
        XCTAssertEqual(evicted, [])
    }

    /// 리뷰에서 잡힌 결함: 다른 화면이 지금 재생 중인 캐시가, 그저 가장 오래
    /// 전에 변환됐다는 이유만으로 LRU 축출에 걸려 지워지면 그 화면이 멎는다.
    /// keep은 "방금 만든 파일 하나"가 아니라 "지금 쓰고 있는 파일들의 집합"
    /// 이어야 한다.
    func testFilesToEvictNeverEvictsInUseFileEvenIfOldest() {
        let oldest = Date(timeIntervalSince1970: 1)   // 원래 LRU면 제일 먼저 지워질 차례
        let middle = Date(timeIntervalSince1970: 2)
        let newest = Date(timeIntervalSince1970: 3)
        let inUse = URL(fileURLWithPath: "/c/inuse.mp4")
        let old2 = URL(fileURLWithPath: "/c/old2.mp4")
        let recent = URL(fileURLWithPath: "/c/recent.mp4")
        let files = [
            VideoConverter.CacheFile(url: inUse, sizeBytes: 40, lastUsedAt: oldest),
            VideoConverter.CacheFile(url: old2, sizeBytes: 40, lastUsedAt: middle),
            VideoConverter.CacheFile(url: recent, sizeBytes: 40, lastUsedAt: newest),
        ]
        // 총합 120, 상한 50. inuse.mp4가 제일 오래됐지만 다른 화면이 재생 중이라
        // keep에 들어간다 — 지우면 안 된다. 대신 old2/recent를 지워 상한을 맞춘다.
        let evicted = VideoConverter.filesToEvict(files, capBytes: 50, keep: [inUse])
        XCTAssertFalse(evicted.contains(inUse), "재생 중인 캐시는 가장 오래됐어도 지우면 안 된다")
        XCTAssertEqual(Set(evicted), Set([old2, recent]))
    }

    // MARK: - convert(): 실행부의 결정적인 부분(실제 ffmpeg 없이 확인 가능한 것)

    func testConvertThrowsWhenFfmpegMissing() {
        let converter = VideoConverter(executable: nil, cacheDirectory: root)
        XCTAssertThrowsError(
            try converter.convert(source: URL(fileURLWithPath: "/x/bg.webm"))
        ) { error in
            XCTAssertEqual(error as? VideoConverterError, .ffmpegNotFound)
        }
    }

    func testConvertReusesExistingCacheWithoutInvokingFfmpeg() throws {
        // executable을 실재하지 않는 가짜 경로로 둔다 — convert()가 캐시를
        // 먼저 보지 않고 곧장 실행을 시도했다면 여기서 던졌을 것이다.
        let bogusExecutable = URL(fileURLWithPath: "/nonexistent/ffmpeg-\(UUID().uuidString)")
        let source = root.appendingPathComponent("bg.webm")
        try Data("fake source".utf8).write(to: source)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast

        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let converter = VideoConverter(executable: bogusExecutable, cacheDirectory: cacheDir)
        let expected = converter.cacheFileURL(sourcePath: source.path, sizeBytes: size, modifiedAt: modified)
        try Data("already converted".utf8).write(to: expected)

        let result = try converter.convert(source: source)
        XCTAssertEqual(result, expected)
    }

    /// 리뷰 Minor 1: 실행 파일이 있다고 판정됐는데(locateExecutable을 거쳤으니)
    /// 막상 Process.run()이 던지면(권한 없음 등) — 그건 "ffmpeg가 없다"가
    /// 아니다. 잘못 붙인 이름으로 던지면 로그·상태 메시지가 실제 원인과 달라진다.
    func testConvertSurfacesProcessRunFailureAsConversionFailedNotFfmpegNotFound() throws {
        let source = root.appendingPathComponent("bg.webm")
        try Data("fake source".utf8).write(to: source)

        // 존재는 하지만 실행 권한이 없는 파일 — Process.run()이 실행을 거부해
        // 던진다(ffmpeg가 "없는" 게 아니라 이 파일을 못 돌린 것뿐이다).
        let notExecutable = root.appendingPathComponent("not-ffmpeg")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)

        let converter = VideoConverter(
            executable: notExecutable, cacheDirectory: root.appendingPathComponent("cache"))
        XCTAssertThrowsError(try converter.convert(source: source)) { error in
            guard case .conversionFailed = error as? VideoConverterError else {
                return XCTFail("ffmpegNotFound로 잘못 붙이면 안 된다: \(error)")
            }
        }
    }

    // MARK: - 메뉴에 보여줄 상태(없음·실패·변환 중은 한국어 사유 표시)

    func testMenuLabelSuffixForEachState() {
        XCTAssertEqual(VideoConverter.menuLabelSuffix(for: .ffmpegMissing), "(ffmpeg 필요)")
        XCTAssertEqual(VideoConverter.menuLabelSuffix(for: .converting), "(변환 중)")
        XCTAssertEqual(VideoConverter.menuLabelSuffix(for: .failed(reason: "x")), "(변환 실패)")
    }

    func testMenuTooltipMentionsFfmpegInstallWhenMissing() {
        XCTAssertTrue(VideoConverter.menuTooltip(for: .ffmpegMissing).contains("ffmpeg"))
    }

    func testMenuTooltipForConvertingExplainsAutoStart() {
        XCTAssertTrue(VideoConverter.menuTooltip(for: .converting).contains("자동으로"))
    }

    func testMenuTooltipForFailedPassesReasonThrough() {
        XCTAssertEqual(VideoConverter.menuTooltip(for: .failed(reason: "이유")), "이유")
    }
}
