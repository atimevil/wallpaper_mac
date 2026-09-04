import AppKit

/// 화면 하나를 덮는 배경 윈도우.
/// 데스크톱 아이콘 바로 아래 레벨에 놓여 모든 스페이스에 머문다.
final class WallpaperWindow: NSWindow {
    let screenID: CGDirectDisplayID

    init(screen: NSScreen) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        screenID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 데스크톱 아이콘 바로 아래. 이보다 높으면 아이콘을 가린다.
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        )

        // 모든 스페이스에 머물고, Mission Control과 창 순환에서 빠진다.
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenNone,
        ]

        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true   // 클릭은 데스크톱으로 통과시킨다
        isReleasedWhenClosed = false
        backgroundColor = .black
        setFrame(screen.frame, display: true)
    }

    /// 이 윈도우의 내용을 교체한다. 렌더러가 뷰를 넘긴다.
    func setContent(_ view: NSView) {
        view.frame = contentView?.bounds ?? frame
        view.autoresizingMask = [.width, .height]
        contentView = view
    }
}
