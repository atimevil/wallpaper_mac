import Foundation
import CryptoKit

public enum VideoConverterError: Error, Equatable {
    case ffmpegNotFound
    /// ffmpeg가 실패했다. log는 마지막 stderr/stdout 일부(진단용, 영어).
    case conversionFailed(exitCode: Int32, log: String)
}

/// webm/mkv처럼 컨테이너 자체를 AVFoundation이 못 여는 비디오를, ffmpeg가 있으면
/// H.264 MP4로 한 번 바꿔 `~/Library/Caches/Wallflow/video`에 캐시해 둔다.
///
/// 탐색 순서·캐시 키·ffmpeg 인자·캐시 축출 같은 "결정"은 전부 순수 함수라
/// VideoConverterTests에서 직접 검증한다. 실제 프로세스 실행(convert)은
/// SteamCmdClient와 같은 자리(WallflowKit)에 둔다 — Foundation만 쓰고
/// AppKit/AVFoundation은 필요 없으니, 붙이는 쪽(DisplayManager)은 "언제"
/// 변환을 걸지만 정하면 된다.
public struct VideoConverter: Sendable {
    public let executable: URL?
    public let cacheDirectory: URL

    public init(executable: URL?, cacheDirectory: URL) {
        self.executable = executable
        self.cacheDirectory = cacheDirectory
    }

    public var isAvailable: Bool { executable != nil }

    /// `~/Library/Caches/Wallflow/video`. macOS Caches 디렉터리는 시스템이
    /// 언제든 지워도 되는 자리라, 재생 가능 여부에는 영향이 없어야 한다 —
    /// 없으면 다시 변환하면 그만이다.
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Wallflow/video", isDirectory: true)
    }

    // MARK: - 분류: 컨테이너만 문제인 비디오인가

    /// 지금 아는 "컨테이너 문제"(webm/mkv)는 전부 코덱과 무관하게 컨테이너
    /// 자체를 AVFoundation이 못 여는 경우다(UnsupportedVideoFormat 문서 참고).
    /// 그래서 ffmpeg로 컨테이너만 바꿔 끼우면(코덱은 새로 인코딩) 재생할 수
    /// 있다 — 즉 이 판정과 "변환 대상"은 지금은 같은 질문이다.
    public static func needsConversion(_ url: URL) -> Bool {
        UnsupportedVideoFormat.isKnownUnsupportedContainer(url)
    }

    // MARK: - ffmpeg 탐색 순서

    /// brew와 수동 설치의 통상 경로. Finder에서 켠 앱(배경화면 앱은 항상 이
    /// 경로로 뜬다)은 로그인 셸의 PATH를 물려받지 않으므로 이 경로들을 먼저
    /// 본다 — SteamCmdClient.defaultSearchPaths와 같은 이유다.
    public static let defaultSearchPaths = [
        URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
    ]

    /// 표준 위치에 없으면 그제서야 PATH를 훑는다. fileExists/pathEnvironment를
    /// 주입할 수 있게 해 테스트가 실제 디스크나 진짜 PATH에 기대지 않는다.
    public static func locateExecutable(
        searching paths: [URL] = defaultSearchPaths,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let hit = paths.first(where: { fileExists($0.path) }) { return hit }
        guard let pathEnvironment else { return nil }
        for entry in pathEnvironment.split(separator: ":") where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("ffmpeg")
            if fileExists(candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - 캐시 키

    /// 원본의 경로+크기+수정시각을 합쳐 해시한다. 셋 중 하나라도 바뀌면(다시
    /// 받았거나 파일이 교체되면) 다른 키가 나와 낡은 캐시를 재생하지 않는다.
    /// 수정시각은 밀리초 정수로 끊어 쓴다 — Double을 문자열로 그대로 넣으면
    /// 부동소수점 표현이 흔들릴 여지가 있다.
    public static func cacheKey(sourcePath: String, sizeBytes: Int64, modifiedAt: Date) -> String {
        let modifiedMs = Int64((modifiedAt.timeIntervalSince1970 * 1000).rounded())
        let raw = "\(sourcePath)|\(sizeBytes)|\(modifiedMs)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func cacheFileURL(sourcePath: String, sizeBytes: Int64, modifiedAt: Date) -> URL {
        cacheDirectory
            .appendingPathComponent(
                Self.cacheKey(sourcePath: sourcePath, sizeBytes: sizeBytes, modifiedAt: modifiedAt))
            .appendingPathExtension("mp4")
    }

    // MARK: - ffmpeg 인자

    /// macOS AVFoundation이 확실히 여는 조합(H.264 + yuv420p)을 강제한다 —
    /// 컨테이너만 바꾸고(-c copy) 안의 VP9/Opus를 그대로 두면 여전히 못 연다.
    /// -an: 배경화면은 항상 음소거로 재생하므로(VideoRenderer) 오디오 트랙은
    /// 애초에 인코딩하지 않는다 — 더 작고 빠르고, Opus→AAC 변환 실패 경로도 없앤다.
    /// -nostdin/-loglevel error: 사람 없이 백그라운드에서 도는 변환이라
    /// 대화식 프롬프트를 막고 로그를 진짜 오류만으로 줄인다.
    /// -f mp4: 출력 컨테이너를 확장자가 아니라 여기서 못박는다. 임시 파일
    /// 이름이 .part(캐시 축출이 헷갈리지 않게, convert() 참고)라 확장자로는
    /// ffmpeg가 muxer를 못 고른다 — 실제 변환에서 겪은 실패라 넣었다.
    public static func arguments(input: URL, output: URL) -> [String] {
        [
            "-y", "-nostdin", "-loglevel", "error",
            "-i", input.path,
            "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mp4",
            output.path,
        ]
    }

    // MARK: - 캐시 상한(2GB, LRU)

    public struct CacheFile: Equatable, Sendable {
        public let url: URL
        public let sizeBytes: Int64
        public let lastUsedAt: Date

        public init(url: URL, sizeBytes: Int64, lastUsedAt: Date) {
            self.url = url
            self.sizeBytes = sizeBytes
            self.lastUsedAt = lastUsedAt
        }
    }

    public static let cacheCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// 총합이 상한을 넘으면 가장 오래 안 쓴 것부터 지울 목록을 고른다.
    /// keep은 절대 포함하지 않는다 — 방금 막 변환을 끝낸 파일 혼자 상한보다
    /// 커도 그것까지 지우면, 고르자마자 다음 선택 때 또 변환해야 하는 무한
    /// 루프가 된다(그럴 땐 상한을 일시적으로 넘긴 채로 둔다).
    public static func filesToEvict(_ files: [CacheFile], capBytes: Int64, keep: URL? = nil) -> [URL] {
        let total = files.reduce(0) { $0 + $1.sizeBytes }
        var over = total - capBytes
        guard over > 0 else { return [] }
        var evicted: [URL] = []
        for file in files.filter({ $0.url != keep }).sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            guard over > 0 else { break }
            evicted.append(file.url)
            over -= file.sizeBytes
        }
        return evicted
    }

    /// 캐시 파일을 지금 막 썼다고 기록한다(수정시각을 지금으로 당긴다).
    /// 상한을 넘었을 때 "오래 안 쓴 것부터" 지우려면 재생할 때마다 갱신해야
    /// 한다 — 안 그러면 변환된 시각 기준으로만 지워져, 자주 쓰는 배경화면도
    /// 어쩌다 먼저 변환됐다는 이유만으로 밀려날 수 있다.
    public static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: - 실행

    /// ffmpeg를 실제로 돌려 mp4를 만든다. 임시 파일에 쓰고 성공했을 때만
    /// 캐시 자리로 이름을 바꾼다 — 도중에 죽거나 실패해도 반쪽짜리 mp4가
    /// 캐시인 척 남지 않는다. 이미 같은 키로 변환된 것이 있으면 그대로 쓴다.
    @discardableResult
    public func convert(source: URL) throws -> URL {
        guard let executable else { throw VideoConverterError.ffmpegNotFound }

        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
        let finalURL = cacheFileURL(sourcePath: source.path, sizeBytes: size, modifiedAt: modified)
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        // .part 확장자를 쓴다 — enforceCacheCap()은 .mp4만 캐시 항목으로 세므로,
        // 쓰는 중인 임시 파일이 용량 계산에 끼어 잘못 지워지는 일이 없다.
        // ponytail: 앱이 변환 도중 강제 종료되면 .part/.log가 고아로 남을 수
        // 있다(2GB 상한에도 안 잡힌다). VideoTexture.sweepOrphanedFiles()처럼
        // 시작 시 훑어 지우는 건 이 캐시가 실제로 문제가 될 때 추가한다.
        let tempURL = cacheDirectory.appendingPathComponent(stem).appendingPathExtension("part")
        let logURL = cacheDirectory.appendingPathComponent(stem).appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(input: source, output: tempURL)
        // 배경화면 렌더링이나 다른 작업을 방해하지 않는다 — 사용자가 요청한
        // 적 없는 백그라운드 인코딩이 CPU를 우선해서 가져가면 안 된다.
        process.qualityOfService = .background
        process.standardInput = FileHandle.nullDevice
        // 출력은 Pipe가 아니라 파일로 받는다. Pipe로 받으면 ffmpeg가 파이프
        // 버퍼(64KB)를 넘기는 순간 쓰다가 막히고, waitUntilExit()도 그걸
        // 기다리며 같이 멈춘다(교착) — 파일은 그런 상한이 없다.
        if let handle = FileHandle(forWritingAtPath: logURL.path) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw VideoConverterError.ffmpegNotFound
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw VideoConverterError.conversionFailed(
                exitCode: process.terminationStatus, log: String(log.suffix(2000)))
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            // 그 사이 같은 키를 다른 프로세스(Wallflow 두 번째 인스턴스 등)가
            // 먼저 끝냈을 수 있다 — 그럼 그 결과를 그대로 쓴다. 아니면 진짜 실패다.
            try? FileManager.default.removeItem(at: tempURL)
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                throw VideoConverterError.conversionFailed(exitCode: -1, log: "\(error)")
            }
        }

        enforceCacheCap(keep: finalURL)
        return finalURL
    }

    /// 캐시 디렉터리를 훑어 2GB 상한을 넘으면 오래 안 쓴 것부터 지운다.
    /// convert() 성공 뒤에 부른다 — 캐시가 자라는 시점은 그때뿐이다.
    public func enforceCacheCap(capBytes: Int64 = VideoConverter.cacheCapBytes, keep: URL? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        let files: [CacheFile] = entries.compactMap { url in
            guard url.pathExtension == "mp4",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return CacheFile(
                url: url, sizeBytes: Int64(size),
                lastUsedAt: values.contentModificationDate ?? .distantPast)
        }
        for url in Self.filesToEvict(files, capBytes: capBytes, keep: keep) {
            try? fm.removeItem(at: url)
        }
    }
}
