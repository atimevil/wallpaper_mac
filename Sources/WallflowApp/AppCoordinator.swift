import AppKit
import WallflowKit

/// 앱 전체를 조립하고 수명을 관리한다.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private var menuBar: MenuBarController?
    private var power: PowerMonitor?
    private let library: LibraryStore
    private let installer: WorkshopInstaller
    private var workshop: WorkshopWindowController?

    /// 마지막으로 고른 배경화면의 id. 배경화면 앱이 켤 때마다 빈 화면으로
    /// 시작하면 매번 메뉴에서 다시 골라야 한다.
    private static let lastSelectionKey = "wallflow.lastSelectedID"

    override init() {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Library")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(root: root)
        // 받은 원본은 라이브러리 밖에 둔다. 라이브러리에서 링크를 지워도 원본이
        // 남아 다시 받지 않아도 된다.
        installer = WorkshopInstaller(
            downloadRoot: root.deletingLastPathComponent()
                .appendingPathComponent("Workshop"),
            libraryRoot: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 강제 종료·SIGKILL·패닉으로 남은 임시 비디오 파일을 정리한다. 씬을
        // 아직 아무것도 열지 않은 시점이라 이 프로세스는 어떤 파일도 잠그고
        // 있지 않으므로, rebuildWindows보다 먼저 불러도 스스로의 파일을 지울
        // 위험이 없다.
        VideoTexture.sweepOrphanedFiles()

        displays.rebuildWindows()

        let power = PowerMonitor(
            occlusionProvider: { [weak self] in self?.displays.isOccluded ?? false },
            onChange: { [weak self] directive in self?.displays.apply(directive) }
        )
        power.start()
        self.power = power

        // 지난번에 켜 뒀으면 이어서 듣는다. 껐으면 아무것도 하지 않는다.
        if AudioSpectrum.isEnabled {
            let source = AudioSpectrum()
            SceneRenderer.audioSource = source
            source.start()
        }

        menuBar = MenuBarController(
            onSelect: { [weak self] item in self?.select(item) },
            onRefresh: { [weak self] in self?.refreshLibrary() },
            onBrowseWorkshop: { [weak self] in self?.showWorkshop() },
            onToggleSound: { [weak self] _ in self?.displays.applySoundSetting() },
            onToggleAudio: { enabled in
                // 소리 듣기는 앱 전체가 하나만 돈다. 화면이 여럿이어도 시스템 소리는 하나다.
                if enabled {
                    let source = SceneRenderer.audioSource ?? AudioSpectrum()
                    SceneRenderer.audioSource = source
                    source.start()
                } else {
                    SceneRenderer.audioSource?.stop()
                }
            },
            onQuit: { NSApp.terminate(nil) }
        )
        refreshLibrary()
        restoreLastSelection()
    }

    /// 지난번에 쓰던 배경화면을 다시 건다.
    ///
    /// 라이브러리에서 사라졌으면 조용히 넘어간다 — 사용자가 지웠거나 옮긴 것이고,
    /// 그 경우 오류를 띄우는 건 도움이 안 된다.
    private func restoreLastSelection() {
        guard let saved = UserDefaults.standard.string(forKey: Self.lastSelectionKey),
              let item = ((try? library.scan()) ?? []).first(where: { $0.id == saved })
        else { return }
        select(item, remember: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        power?.stop()
        displays.stopAll()
    }

    /// 창작마당 창을 띄운다. 이미 떠 있으면 앞으로 가져온다.
    private func showWorkshop() {
        if workshop == nil {
            workshop = WorkshopWindowController(
                installer: installer,
                libraryItems: { [weak self] in (try? self?.library.scan()) ?? [] },
                onApply: { [weak self] item in self?.select(item) },
                onLibraryChanged: { [weak self] in self?.refreshLibrary() })
        }
        // 메뉴바 전용 앱이라 창을 띄우려면 앱을 활성화해야 한다.
        NSApp.activate(ignoringOtherApps: true)
        workshop?.showWindow(nil)
        workshop?.window?.makeKeyAndOrderFront(nil)
    }

    private func refreshLibrary() {
        let items = (try? library.scan()) ?? []
        menuBar?.setItems(items)
    }

    /// - Parameter remember: 복원 중에는 저장하지 않는다. 저장된 값을 그대로
    ///   다시 쓰는 것이라 의미가 없고, 실패해도 선택을 지우지 않아야 한다.
    private func select(_ item: WallpaperItem, remember: Bool = true) {
        do {
            try displays.assign(item, toDisplay: nil)
            if remember {
                UserDefaults.standard.set(item.id, forKey: Self.lastSelectionKey)
            }
        } catch {
            // 배경화면은 항상 켜져 있어야 한다. 실패해도 앱을 죽이지 않는다.
            FileHandle.standardError.write(Data("배경화면 적용 실패: \(error)\n".utf8))
        }
    }
}
