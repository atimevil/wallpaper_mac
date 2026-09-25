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
        switch item.type {
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
            throw error
        }
        renderer.apply(lastDirective)
        renderers[id] = renderer
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

    /// 화면 맞춤 방식을 이 배경화면을 지금 보여주고 있는 모든 렌더러에 즉시
    /// 적용한다. 같은 배경화면을 여러 화면에 걸었으면 전부에게 간다. 씬이 아닌
    /// 렌더러(비디오·웹)는 캐스트가 실패해 조용히 건너뛴다 — 애초에 씬만
    /// 화면 맞춤을 쓴다.
    func applyCanvasFit(_ mode: CanvasFit.Mode, toWallpaperID id: String) {
        for (displayID, renderer) in renderers where assignments[displayID]?.id == id {
            (renderer as? SceneRenderer)?.setCanvasFit(mode)
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
