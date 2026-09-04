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

    /// 배경 윈도우가 전부 가려졌는지. PowerMonitor가 poll 시점에 읽는다.
    var isOccluded: Bool {
        guard !windows.isEmpty else { return false }
        // 하나라도 보이면 그린다.
        return !windows.values.contains { $0.occlusionState.contains(.visible) }
    }

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

            // 이 화면에 배정이 있었으면 복원한다.
            if let item = assignments[id] {
                try? attach(item, to: id)
            }
        }
    }

    /// 배경화면을 배정한다. displayID가 nil이면 모든 화면에 건다.
    func assign(_ item: WallpaperItem, toDisplay id: CGDirectDisplayID?) throws {
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
            showPreview(item, in: window)
            throw RendererError.unsupportedType(item.type)
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
