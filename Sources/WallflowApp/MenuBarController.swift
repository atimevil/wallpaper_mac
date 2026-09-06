import AppKit
import WallflowKit

/// 메뉴바 아이콘과 배경화면 목록 메뉴.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onSelect: (WallpaperItem) -> Void
    private let onRefresh: () -> Void
    private let onBrowseWorkshop: () -> Void
    private let onToggleSound: (Bool) -> Void
    private let onQuit: () -> Void
    private var items: [WallpaperItem] = []

    init(
        onSelect: @escaping (WallpaperItem) -> Void,
        onRefresh: @escaping () -> Void,
        onBrowseWorkshop: @escaping () -> Void,
        onToggleSound: @escaping (Bool) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggleSound = onToggleSound
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.onBrowseWorkshop = onBrowseWorkshop
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallflow"
        )
        rebuildMenu()
    }

    func setItems(_ items: [WallpaperItem]) {
        self.items = items
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // 항목을 직접 활성/비활성 하려면 자동 활성화를 꺼야 한다.
        menu.autoenablesItems = false

        if items.isEmpty {
            let empty = NSMenuItem(title: "배경화면 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, item) in items.enumerated() {
                let menuItem = NSMenuItem(
                    title: "\(item.title)  (\(item.type.rawValue))",
                    action: #selector(select(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                // 씬은 M2부터 이미지 레이어를 그린다. 못 그리면 preview로 폴백한다.
                menuItem.isEnabled = (item.type != .unsupported)
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())
        let login = NSMenuItem(
            title: "로그인할 때 시작", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let sound = NSMenuItem(
            title: "씬 소리", action: #selector(toggleSound), keyEquivalent: "s")
        sound.target = self
        // 배경화면이 로그인할 때마다 소리를 내면 곤란하므로 기본은 꺼짐이다.
        sound.state = UserDefaults.standard.bool(forKey: Self.soundKey) ? .on : .off
        menu.addItem(sound)

        let browse = NSMenuItem(
            title: "창작마당 둘러보기…", action: #selector(browseWorkshop), keyEquivalent: "w")
        browse.target = self
        menu.addItem(browse)

        let refresh = NSMenuItem(title: "라이브러리 새로고침", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    static let soundKey = "wallflow.soundEnabled"

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if let reason = LoginItem.setEnabled(enable) {
            // 실패해도 체크 표시를 바꾸지 않는다. 켜졌다고 거짓말하면 안 된다.
            let alert = NSAlert()
            alert.messageText = enable ? "로그인 항목으로 등록하지 못했다" : "등록을 해제하지 못했다"
            alert.informativeText = LoginItem.isDeniedByUser
                ? "시스템 설정 > 일반 > 로그인 항목에서 Wallflow를 허용해 주세요."
                : reason
            alert.runModal()
        }
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        UserDefaults.standard.set(enabled, forKey: Self.soundKey)
        sender.state = enabled ? .on : .off
        onToggleSound(enabled)
    }

    @objc private func browseWorkshop() { onBrowseWorkshop() }

    @objc private func select(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func refresh() { onRefresh() }
    @objc private func quit() { onQuit() }
}
