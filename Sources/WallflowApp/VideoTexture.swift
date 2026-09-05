import AVFoundation
import CoreVideo
import Metal
import Foundation
import Darwin

enum VideoTextureError: Error {
    case cacheCreationFailed
    case temporaryFileFailed(String)
    case assetNotPlayable
}

/// .tex 안에 들어 있던 MP4를 재생하며 프레임마다 Metal 텍스처를 내놓는다.
///
/// 검증된 사실 두 가지가 이 구현을 규정한다.
///
/// 1) AVPlayerItemVideoOutput → copyPixelBuffer → CVMetalTextureCache 경로는 동작한다.
///    3200x1800 H.264에서 MTLTexture 생성을 확인했다.
/// 2) **AVPlayerLooper와 함께 쓸 수 없다.** 루퍼는 템플릿 아이템의 복사본을
///    재생하므로 템플릿에 붙인 출력은 프레임을 한 장도 받지 못한다. 실측에서
///    0프레임이었다. 그래서 루프는 didPlayToEndTime 알림에서 되감아 처리한다.
@MainActor
final class VideoTexture {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let cache: CVMetalTextureCache
    private let temporaryURL: URL
    /// CVMetalTexture를 살려둬야 그것이 감싼 MTLTexture가 유효하다.
    private var retainedFrame: CVMetalTexture?
    /// deinit에서 만져야 하므로 비격리로 둔다. @MainActor deinit을 쓰면 마지막
    /// 해제가 메인 밖에서 일어날 때 해제가 비동기로 미뤄지고, 그러면 226MB짜리
    /// 임시 파일 삭제도 함께 늦어진다. 이 프로퍼티는 init/stop/deinit에서만
    /// 만지고 전부 사실상 단일 스레드다.
    private nonisolated(unsafe) var endObserver: NSObjectProtocol?
    /// temporaryURL에 대한 배타적 advisory 잠금(flock). 열려 있는 동안은 이
    /// 프로세스가 파일을 쓰고 있다는 뜻이고, sweepOrphanedFiles()가 이 잠금을
    /// 시도해 실패하면 그 파일을 건드리지 않는다 — 두 번째로 실행 중인 Wallflow
    /// 인스턴스의 파일을 지우지 않기 위해서다.
    /// endObserver와 같은 이유로 비격리다: deinit에서 닫아야 한다.
    private nonisolated(unsafe) var lockDescriptor: Int32 = -1

    private(set) var isPlaying = false
    /// currentTexture()가 실패를 한 번 stderr에 알렸으면 다시 알리지 않는다.
    /// 매 프레임(최대 30fps) 호출되므로 그대로 두면 로그가 초 단위로 넘친다.
    private var reportedFailure = false

    /// 재생 중이던 항목이 디코딩 실패로 끝났는가.
    ///
    /// 정직하게 말해두자면 이 프로퍼티가 잡는 실패는 제한적이다. AVFoundation은
    /// 애셋을 비동기로 검사하므로 init 직후에는 status가 거의 항상 .unknown이고,
    /// 트렁케이트/제로 바이트/비H.264 페이로드의 실패 판정은 그보다 늦게, 재생이
    /// 시작된 뒤에야 .failed로 확정된다. 즉 init 시점 검사는 "이미 동기적으로
    /// 실패가 확정된" 드문 경우만 잡고, 나머지는 currentTexture()가 매 프레임
    /// 다시 물어봐야 잡힌다 (아래 참고).
    var hasFailed: Bool {
        player.currentItem?.status == .failed
    }

    init(mp4: Data, device: MTLDevice) throws {
        // AVAsset은 URL을 요구한다. 메모리에서 직접 읽으려면
        // AVAssetResourceLoaderDelegate가 필요한데, M3는 단순한 임시 파일로 간다.
        // 226MB짜리가 있으므로 M4 이후 리소스 로더로 바꿀 여지를 남긴다.
        //
        // 별도 하위 디렉터리에 쓴다. 강제 종료·SIGKILL·패닉으로 stop()/deinit이
        // 돌지 못하면 이 파일이 고아로 남는데, 전용 폴더여야 다음 실행 때 그
        // 폴더만 훑어 안전하게 정리할 수 있다 (sweepOrphanedFiles(), AppCoordinator에서 호출).
        let directory = Self.temporaryVideoDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wallflow-video-\(UUID().uuidString).mp4")

        // 파일을 "만들기+잠그기"를 하나의 syscall로 묶는다. Data.write(options:.atomic)를
        // 쓰면 Foundation이 같은 폴더에 이름이 다른 스크래치 파일을 먼저 쓰고 나중에
        // rename하는데, 226MB 페이로드에서 그 사이의 시간 동안 스크래치 파일도
        // temporaryURL도 아무 잠금 없이 디렉터리에 놓여 있어 sweepOrphanedFiles()가
        // 지울 수 있었다. O_EXLOCK은 open()이 성공하는 바로 그 순간 파일을 만들고
        // 배타적으로 잠그는 것을 원자적으로 보장하는 BSD 확장이라 — flock()을 별도
        // 호출로 나중에 걸 때 생기는 "만들어졌지만 아직 안 잠긴" 틈이 아예 없다.
        // O_EXCL은 (사실상 불가능하지만) UUID 충돌 시 기존 파일을 덮어쓰지 않는다.
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            throw VideoTextureError.temporaryFileFailed("임시 파일 생성/잠금 실패 (errno \(errno))")
        }
        lockDescriptor = fd
        temporaryURL = url

        // 이제 파일은 이미 생성되고 잠긴 상태다. sweepOrphanedFiles()가 이 시점부터
        // 쓰기가 끝날 때까지 이 파일을 보더라도 flock에 실패해 건드리지 못한다.
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: mp4)
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: url)
            throw VideoTextureError.temporaryFileFailed("\(error)")
        }

        var created: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &created) == kCVReturnSuccess,
              let cache = created else {
            close(fd)
            try? FileManager.default.removeItem(at: url)
            throw VideoTextureError.cacheCreationFailed
        }
        self.cache = cache

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)

        player = AVPlayer(playerItem: item)
        player.isMuted = true          // 배경화면은 소리를 내지 않는다
        player.actionAtItemEnd = .none

        // 루퍼를 쓸 수 없으므로 끝에서 되감는다.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                // apply(.paused)가 같은 런루프 턴에 큐잉된 종료 알림과 겹치면,
                // 무조건 play()를 부르는 순간 화면이 멈춘 채로 디코딩만 계속 돌아
                // 전력 정책이 막으려던 상태를 정확히 만든다. isPlaying으로 그
                // 의도를 확인한 뒤에만 되감기 재생한다.
                guard let self, self.isPlaying else { return }
                player?.play()
            }
        }
    }

    /// 임시 비디오 파일 전용 디렉터리. AppCoordinator가 시작 시 이 폴더를 훑어
    /// 고아 파일을 정리한다.
    nonisolated static func temporaryVideoDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WallflowVideoTextures")
    }

    /// 강제 종료·SIGKILL·패닉으로 stop()/deinit이 돌지 못해 남은 임시 비디오
    /// 파일을 정리한다. 앱 시작 시 한 번 부른다 (AppCoordinator 참고).
    ///
    /// 같은 폴더를 다른 Wallflow 인스턴스가 지금 쓰고 있을 수 있다. 파일마다
    /// 비차단 flock을 시도해, 잠글 수 있는(=아무도 쓰고 있지 않은) 파일만
    /// 지운다. 잠금에 실패하면 다른 인스턴스가 쥐고 있다는 뜻이므로 건드리지
    /// 않는다 — 두 번째 인스턴스의 파일을 지우는 문제는 추측이 아니라 이렇게
    /// 직접 확인해서 피한다.
    nonisolated static func sweepOrphanedFiles() {
        let directory = temporaryVideoDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        for url in entries {
            // 이 폴더가 우리가 만든 파일만 담는다는 보장이 사라질 수 있으니(예: 사용자가
            // 직접 뭔가 떨어뜨렸거나, 미래에 다른 이름 규칙이 섞여 들어오거나) 이름
            // 패턴부터 확인한다. VideoTexture.init이 만드는 이름과 정확히 일치하는
            // 파일만 대상으로 삼는다.
            guard url.lastPathComponent.hasPrefix("wallflow-video-"),
                  url.pathExtension == "mp4" else { continue }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func releaseLock() {
        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if lockDescriptor >= 0 { close(lockDescriptor) }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        isPlaying = false
        retainedFrame = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        releaseLock()
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// 지금 보여줄 프레임. 새 프레임이 없으면 직전 것을 그대로 돌려준다.
    func currentTexture() -> MTLTexture? {
        // init 시점 검사(hasFailed)가 놓치는 대부분의 실패가 여기서 잡힌다 — 재생이
        // 시작된 뒤에야 AVFoundation이 status를 .failed로 확정하기 때문이다. 매
        // 프레임 호출되므로 한 번만 stderr에 알리고, 이후로는 조용히 nil 취급한다.
        if hasFailed {
            if !reportedFailure {
                reportedFailure = true
                let reason = player.currentItem?.error?.localizedDescription ?? "알 수 없는 오류"
                FileHandle.standardError.write(Data(
                    "비디오 텍스처 재생 실패, 이 레이어는 더 이상 그려지지 않는다: \(reason)\n".utf8))
            }
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }

        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var created: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &created)
        guard result == kCVReturnSuccess, let created else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }
        retainedFrame = created
        // 참조가 끊긴 텍스처를 캐시가 놓아주게 한다. 비우지 않으면 며칠 켜두는
        // 배경화면에서 메모리가 계속 는다.
        CVMetalTextureCacheFlush(cache, 0)
        return CVMetalTextureGetTexture(created)
    }
}
