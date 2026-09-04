import AppKit

// Task 5 확인용 임시 진입점. Task 8에서 AppCoordinator로 교체한다.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WallpaperWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for screen in NSScreen.screens {
            let window = WallpaperWindow(screen: screen)
            let view = NSView(frame: window.frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.cgColor
            window.setContent(view)
            window.orderFront(nil)
            windows.append(window)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock에 뜨지 않는다
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
