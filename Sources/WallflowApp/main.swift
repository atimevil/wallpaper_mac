import AppKit
import WallflowKit

// Task 6 확인용 임시 진입점. Task 8에서 AppCoordinator로 교체한다.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WallpaperWindow] = []
    private var renderers: [WallpaperRenderer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["WALLFLOW_ITEM"] else {
            FileHandle.standardError.write(Data("WALLFLOW_ITEM 환경변수에 배경화면 폴더 경로를 넣어라\n".utf8))
            NSApp.terminate(nil)
            return
        }
        do {
            let item = try WallpaperItem.load(from: URL(fileURLWithPath: path))
            for screen in NSScreen.screens {
                let window = WallpaperWindow(screen: screen)
                let renderer: WallpaperRenderer
                switch item.type {
                case .video:
                    renderer = VideoRenderer(item: item)
                case .web:
                    renderer = WebRenderer(item: item)
                case .scene, .unsupported:
                    throw RendererError.unsupportedType(item.type)
                }
                window.setContent(renderer.makeView())
                try renderer.start()
                window.orderFront(nil)
                windows.append(window)
                renderers.append(renderer)
            }
        } catch {
            FileHandle.standardError.write(Data("실패: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
