import AppKit
import WallflowKit

/// 메뉴바 아이콘과 배경화면 목록 메뉴.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onSelect: (WallpaperItem) -> Void
    private let onRefresh: () -> Void
    private let onQuit: () -> Void
    private var items: [WallpaperItem] = []

    init(
        onSelect: @escaping (WallpaperItem) -> Void,
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onRefresh = onRefresh
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
                // M1은 씬을 재생하지 못한다. 고를 수 없게 둔다.
                menuItem.isEnabled = (item.type == .video || item.type == .web)
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "라이브러리 새로고침", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func refresh() { onRefresh() }
    @objc private func quit() { onQuit() }
}
