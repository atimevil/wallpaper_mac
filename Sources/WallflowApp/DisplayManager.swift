import AppKit
import WallflowKit

/// 화면별 배경 윈도우와 렌더러를 소유한다.
/// 디스플레이가 붙고 떨어질 때 윈도우를 재구성하고 배정을 유지한다.
@MainActor
final class DisplayManager {
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var renderers: [CGDirectDisplayID: WallpaperRenderer] = [:]
    /// 어떤 화면에 어떤 배경화면이 배정됐는지. 재구성 후 복원에 쓴다.
    private var assignments: [CGDirectDisplayID: WallpaperItem] = [:]
    private var lastDirective: PlaybackDirective = .playing(fps: PowerPolicy.normalFPS)

    /// webm/mkv를 ffmpeg로 바꿔 재생하는 경로가 쓴다. ffmpeg 위치는 앱이 켜져
    /// 있는 동안 안 바뀐다고 보고 한 번만 찾는다.
    private let videoConverter = VideoConverter(
        executable: VideoConverter.locateExecutable(),
        cacheDirectory: VideoConverter.defaultCacheDirectory)
    /// 지금 백그라운드에서 변환 중인 원본 경로. 화면이 여럿이거나 재구성이
    /// 겹쳐도 같은 파일을 두 번 변환하지 않으려고 둔다.
    private var activeConversions: Set<URL> = []
    /// 이번 실행에서 변환이 실패한 원본과 그 이유. 깨진 파일은 다시 돌려도
    /// 똑같이 실패하므로, 화면이 바뀔 때마다 헛되이 재시도하지 않는다.
    private var conversionFailures: [URL: String] = [:]
    /// 변환 상태가 바뀔 때(시작/성공/실패) 불린다. 메뉴의 "(변환 중)" 같은
    /// 표시를 다시 그리게 하는 데 쓴다 — AppCoordinator가 menuBar.refreshStates로 잇는다.
    var onConversionStateChanged: (() -> Void)?
    /// 모든 화면에 건 배경화면. 새로 연결된 모니터에도 이것을 건다.
    ///
    /// 배정 이력이 없는 화면을 빈 채로 두면, 모니터를 꽂았을 때 거기만
    /// 기본 바탕화면이 보인다. 쓰던 배경화면이 확장되는 것이 기대에 맞다.
    private var defaultItem: WallpaperItem?

    /// 지금 모든 화면에 걸린 배경화면. 설정 창이 속성 탭을 채울 때 본다.
    var currentItem: WallpaperItem? { defaultItem }

    /// 걸린 배경화면을 다시 연다. 사용자 속성은 씬을 읽을 때 얹히므로,
    /// 값이 바뀌면 이렇게 다시 읽어야 먹는다.
    func reloadCurrent() {
        guard let item = defaultItem else { return }
        try? assign(item, toDisplay: nil)
    }

    /// 배경 윈도우가 전부 가려졌는지. PowerMonitor가 poll 시점에 읽는다.
    var isOccluded: Bool {
        guard !windows.isEmpty else { return false }
        // 하나라도 보이면 그린다.
        let occluded = !windows.values.contains { $0.occlusionState.contains(.visible) }
        if occluded != lastLoggedOcclusion {
            lastLoggedOcclusion = occluded
            // "배경화면이 검다"는 신고의 첫 번째 원인이 이것이다. 가려지면 그리기를
            // 멈추는 것이 의도된 동작이라는 걸 로그로 구별할 수 있어야 한다.
            FileHandle.standardError.write(Data(
                (occluded
                    ? "배경 윈도우가 전부 가려져 그리기를 멈춘다\n"
                    : "배경 윈도우가 보여 그리기를 재개한다\n").utf8))
        }
        return occluded
    }

    private var lastLoggedOcclusion: Bool?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() {
        MainActor.assumeIsolated { rebuildWindows() }
    }

    func rebuildWindows() {
        let live = Set(NSScreen.screens.compactMap(Self.displayID(of:)))

        // 사라진 화면을 정리한다.
        for id in windows.keys where !live.contains(id) {
            renderers[id]?.stop()
            renderers[id] = nil
            windows[id]?.orderOut(nil)
            windows[id] = nil
        }

        // 새 화면에 윈도우를 만든다.
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
                continue
            }
            let window = WallpaperWindow(screen: screen)
            window.orderFront(nil)
            windows[id] = window

            // 이 화면에 배정이 있었으면 그것을, 없으면 지금 쓰는 것을 건다.
            if let item = assignments[id] ?? defaultItem {
                assignments[id] = item
                try? attach(item, to: id)
            }
        }
    }

    /// 배경화면을 배정한다. displayID가 nil이면 모든 화면에 건다.
    func assign(_ item: WallpaperItem, toDisplay id: CGDirectDisplayID?) throws {
        // 화면을 특정하지 않았으면 앞으로 연결될 화면에도 이것을 건다.
        if id == nil { defaultItem = item }
        let targets = id.map { [$0] } ?? Array(windows.keys)
        guard !targets.isEmpty else { return }
        var firstError: Error?
        for target in targets {
            assignments[target] = item
            do {
                try attach(item, to: target)
            } catch {
                // 화면 하나가 실패해도 나머지는 계속 건다.
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func attach(_ item: WallpaperItem, to id: CGDirectDisplayID) throws {
        guard let window = windows[id] else { return }

        renderers[id]?.stop()
        renderers[id] = nil

        let renderer: WallpaperRenderer
        // 변환 캐시로 재생하다 start()가 실패하면(캐시가 깨졌거나, 확인과 재생
        // 사이에 축출됐거나) 그 캐시 파일을 지운다 — 안 지우면 존재만으로
        // "캐시 있음"이라 판정해 다음에도 같은 망가진 파일을 골라 영원히
        // 실패한다. 원본(webm/mkv) 쪽 실패는 이 대상이 아니라 nil로 둔다.
        var cacheToInvalidateOnFailure: URL?
        switch item.type {
        case .video where VideoConverter.needsConversion(item.contentURL):
            // webm/mkv: 캐시된 mp4가 있으면 그것으로 재생하고, 없으면 미리보기 +
            // 이유를 보여준 채로 끝낸다(아래 참고 — 여기서는 던지지 않는다).
            guard let playbackURL = try resolveConvertedVideo(item, window: window) else { return }
            cacheToInvalidateOnFailure = playbackURL
            renderer = VideoRenderer(item: item, playbackURL: playbackURL)
        case .video:
            renderer = VideoRenderer(item: item)
        case .web:
            renderer = WebRenderer(item: item)
        case .scene:
            renderer = SceneRenderer(item: item)
        case .unsupported:
            // 미리보기라도 띄운다. 검은 화면보다는 낫고, 이유는 함께 알린다.
            showPreview(item, in: window)
            throw item.unsupportedReason.map { RendererError.unopenable($0) }
                ?? RendererError.unsupportedType(item.type)
        }

        window.setContent(renderer.makeView())
        do {
            try renderer.start()
        } catch {
            // 렌더가 실패해도 배경이 검게 남지 않게 한다.
            showPreview(item, in: window)
            if let cacheToInvalidateOnFailure {
                try? FileManager.default.removeItem(at: cacheToInvalidateOnFailure)
            }
            throw error
        }
        renderer.apply(lastDirective)
        renderers[id] = renderer
    }

    /// webm/mkv처럼 컨테이너 문제인 비디오를 붙인다. 캐시된 mp4가 있으면 그
    /// 경로를 준다. 없으면 미리보기를 띄우고(필요하면 변환을 background로
    /// 건 뒤) nil을 준다.
    ///
    /// **여기서는 변환 중·실패를 오류로 던지지 않는다.** 던지면 그걸 부른
    /// assign()이 실패로 보고, AppCoordinator.select()는 실패한 선택을
    /// "마지막으로 고른 배경화면"에 저장하지 않는다 — 그러면 변환이 몇 초 뒤
    /// 끝나 잘 재생되더라도, 다음 앱 실행 때는 이 선택이 복원되지 않는다.
    /// 던지는 건 ffmpeg가 아예 없어 이 세션에서는 절대 못 여는 경우뿐이다.
    private func resolveConvertedVideo(_ item: WallpaperItem, window: WallpaperWindow) throws -> URL? {
        let source = item.contentURL

        if let cached = cachedVideoURL(for: source) {
            VideoConverter.touch(cached)   // LRU: 방금 썼다고 기록해 둔다
            return cached
        }

        showPreview(item, in: window)

        guard videoConverter.isAvailable else {
            throw RendererError.unopenable("ffmpeg가 없어 \(source.pathExtension) 파일을 열 수 없다")
        }
        if let failure = conversionFailures[source] {
            logConversionStatus(item, failure)
            return nil
        }
        logConversionStatus(item, "\(source.pathExtension) 파일을 MP4로 바꾸는 중이다")
        startConversionIfNeeded(item: item)
        return nil
    }

    /// 이 원본에 해당하는 캐시 mp4가 이미 있으면 그 경로를 준다.
    private func cachedVideoURL(for source: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = attrs[.size] as? Int64,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        let url = videoConverter.cacheFileURL(sourcePath: source.path, sizeBytes: size, modifiedAt: modified)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 이미 같은 원본을 변환 중이면 다시 걸지 않는다. background QoS로 돌려
    /// 배경화면 렌더링이나 다른 작업을 방해하지 않는다.
    private func startConversionIfNeeded(item: WallpaperItem) {
        let source = item.contentURL
        guard !activeConversions.contains(source) else { return }
        activeConversions.insert(source)
        onConversionStateChanged?()
        let converter = videoConverter
        // 변환이 끝나 캐시 상한을 넘겨 정리할 때, 지금 다른 화면이 재생 중인
        // 캐시까지 같이 지워지면 그 화면이 멎는다 — 시작 시점 스냅샷을 넘겨
        // convert()가 그 파일들은 축출 후보에서 아예 뺀다.
        let inUse = inUseCacheURLs()

        // Process는 여기(detached 클로저 안)에서만 만든다 — Sendable이 아니라
        // MainActor 쪽으로 넘길 수 없다. WorkshopWindowController의 steamcmd
        // 다운로드와 같은 모양이다: 바깥 Task는 MainActor를 물려받아 결과가
        // 오면 곧장 self를 만질 수 있고, 무거운 작업만 detached로 뺀다.
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .background) {
                Result { try converter.convert(source: source, keep: inUse) }
            }.value

            guard let self else { return }
            self.activeConversions.remove(source)
            switch result {
            case .success:
                self.conversionFailures[source] = nil
                self.reattachIfStillAssigned(itemID: item.id, source: source)
            case .failure(let error):
                self.conversionFailures[source] = "\(source.pathExtension) 파일을 MP4로 바꾸지 못했다"
                FileHandle.standardError.write(Data(
                    "\(item.title): webm/mkv를 mp4로 바꾸지 못했다 — \(error)\n".utf8))
            }
            self.onConversionStateChanged?()
        }
    }

    /// 지금 어떤 화면이든 재생 중인 캐시 mp4 경로들. LRU 축출이 "가장 오래
    /// 안 쓴 것부터" 지울 때, 변환된 시각만 보면 지금 재생 중인 캐시가 그저
    /// 제일 먼저 변환됐다는 이유만으로 뽑힐 수 있다 — 재생 중인 화면이 멎는
    /// 결과를 낳는다. touch()가 재생 시작마다 갱신은 하지만, 변환이 도는
    /// 수 초~수십 초 동안은 그 시점 스냅샷으로 방어해야 한다.
    private func inUseCacheURLs() -> Set<URL> {
        Set(assignments.values.compactMap { item -> URL? in
            guard VideoConverter.needsConversion(item.contentURL) else { return nil }
            return cachedVideoURL(for: item.contentURL)
        })
    }

    /// 변환이 끝났을 때, 그 배경화면이 아직 걸려 있는 화면이 있으면 재시작
    /// 없이 다시 붙여 재생을 시작한다.
    private func reattachIfStillAssigned(itemID: String, source: URL) {
        for (displayID, assigned) in assignments
        where assigned.id == itemID && assigned.contentURL == source {
            try? attach(assigned, to: displayID)
        }
    }

    private func logConversionStatus(_ item: WallpaperItem, _ message: String) {
        FileHandle.standardError.write(Data("\(item.title): \(message)\n".utf8))
    }

    /// 이 항목이 변환이 필요한 비디오라면 지금 상태를 준다(메뉴 표시용).
    /// 캐시가 있어 정상 재생되거나 아직 변환을 시도한 적 없으면(골라야
    /// 시작한다) 평소 라벨과 다를 게 없어 nil을 준다.
    func conversionState(for item: WallpaperItem) -> VideoConverter.VideoConversionState? {
        guard item.type == .video, VideoConverter.needsConversion(item.contentURL) else { return nil }
        let source = item.contentURL
        if cachedVideoURL(for: source) != nil { return nil }
        guard videoConverter.isAvailable else { return .ffmpegMissing }
        if activeConversions.contains(source) { return .converting }
        if let failure = conversionFailures[source] { return .failed(reason: failure) }
        return nil
    }

    /// 렌더가 불가능하거나 실패했을 때의 폴백. 배경이 검게 남지 않게 한다.
    private func showPreview(_ item: WallpaperItem, in window: WallpaperWindow) {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        if let url = item.previewURL, let image = NSImage(contentsOf: url) {
            view.image = image
        }
        window.setContent(view)
    }

    /// 소리 설정이 바뀌면 씬 렌더러들에게 알린다.
    /// 씬만 소리를 낸다 — 비디오는 자체 오디오 트랙을 쓰고 웹은 해당 없다.
    func applySoundSetting() {
        for renderer in renderers.values {
            (renderer as? SceneRenderer)?.applySoundSetting()
        }
    }

    func apply(_ directive: PlaybackDirective) {
        lastDirective = directive
        for renderer in renderers.values {
            renderer.apply(directive)
        }
    }

    func stopAll() {
        for renderer in renderers.values { renderer.stop() }
        renderers.removeAll()
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
