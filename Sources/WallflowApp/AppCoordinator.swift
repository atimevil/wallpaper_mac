import AppKit
import WallflowKit

/// 앱 전체를 조립하고 수명을 관리한다.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private var menuBar: MenuBarController?
    private var power: PowerMonitor?
    private let library: LibraryStore

    override init() {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Library")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(root: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        displays.rebuildWindows()

        let power = PowerMonitor(
            occlusionProvider: { [weak self] in self?.displays.isOccluded ?? false },
            onChange: { [weak self] directive in self?.displays.apply(directive) }
        )
        power.start()
        self.power = power

        menuBar = MenuBarController(
            onSelect: { [weak self] item in self?.select(item) },
            onRefresh: { [weak self] in self?.refreshLibrary() },
            onQuit: { NSApp.terminate(nil) }
        )
        refreshLibrary()
    }

    func applicationWillTerminate(_ notification: Notification) {
        power?.stop()
        displays.stopAll()
    }

    private func refreshLibrary() {
        let items = (try? library.scan()) ?? []
        menuBar?.setItems(items)
    }

    private func select(_ item: WallpaperItem) {
        do {
            try displays.assign(item, toDisplay: nil)
        } catch {
            // 배경화면은 항상 켜져 있어야 한다. 실패해도 앱을 죽이지 않는다.
            FileHandle.standardError.write(Data("배경화면 적용 실패: \(error)\n".utf8))
        }
    }
}
