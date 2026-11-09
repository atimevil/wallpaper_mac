import AppKit
import UniformTypeIdentifiers
import WallflowKit

/// 앱 전체를 조립하고 수명을 관리한다.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private var menuBar: MenuBarController?
    private var power: PowerMonitor?
    private var idleFullscreen: IdleFullscreenController?
    private var rotation: RotationController?
    private let library: LibraryStore
    /// 배경을 고르면 걸 화면. nil이면 모든 화면. 메뉴와 창작마당 창의 "적용"이 같이 쓴다.
    /// 저장하지 않는다 — 재시작하면 "모든 화면"(안전한 쪽).
    private var applyTarget: CGDirectDisplayID?

    /// 지금 연결된 화면일 때만 대상으로 친다. 대상 화면을 빼면 "모든 화면"으로 돌아간다.
    private var effectiveTarget: CGDirectDisplayID? {
        guard let applyTarget, displays.screensInfo().contains(where: { $0.id == applyTarget })
        else { return nil }
        return applyTarget
    }

    /// "지금 배경": 메뉴(소리 크기·화면 맞춤·삭제·빼기)·설정 창·창작마당 강조가 보는 기준.
    /// 대상 화면에 걸린 배경, "모든 화면"이면 기본 배경.
    private var currentItem: WallpaperItem? {
        effectiveTarget.flatMap { displays.item(onDisplay: $0) } ?? displays.currentItem
    }
    private let installer: WorkshopInstaller
    private var workshop: WorkshopWindowController?
    private var settings: SettingsWindowController?

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

        // 재연결된 모니터에는 그 화면에 따로 건 배경을 찾아 건다(저장된 화면별 지정).
        displays.itemForNewDisplay = { [weak self] id in
            guard let self,
                  let key = self.displays.screensInfo().first(where: { $0.id == id })?.key,
                  let itemID = DisplaySelectionStore.load()[key] else { return nil }
            return ((try? self.library.scan()) ?? []).first { $0.id == itemID }
        }
        displays.rebuildWindows()

        let idleFullscreen = IdleFullscreenController(
            setRaised: { [weak self] raised in self?.displays.setWallpaperWindowsRaised(raised) })
        self.idleFullscreen = idleFullscreen

        let power = PowerMonitor(
            occlusionProvider: { [weak self] in self?.displays.isOccluded ?? false },
            fullscreenShowcaseActive: { [weak self] in self?.idleFullscreen?.isActive ?? false },
            onChange: { [weak self] directive in self?.displays.apply(directive) }
        )
        power.start()
        self.power = power
        idleFullscreen.reload()   // 설정이 켜져 있으면 감시를 시작한다

        // 소리는 **쓰는 씬을 걸었을 때만** 듣는다. 앱이 뜰 때 무조건 켜면 오디오를
        // 안 쓰는 배경화면에서도 macOS가 화면 녹화 권한을 물어 "시스템 설정 열기"
        // 창이 실행마다 뜬다. 렌더러가 씬을 읽고 필요 여부를 알려 준다.
        SceneRenderer.audioNeedChanged = { [weak self] needed in
            self?.audioNeeded = needed
            self?.applyAudioCapture()
        }

        menuBar = MenuBarController(
            onSelect: { [weak self] item in self?.select(item) },
            conversionState: { [weak self] item in self?.displays.conversionState(for: item) },
            onRefresh: { [weak self] in self?.refreshLibrary() },
            onBrowseWorkshop: { [weak self] in self?.showWorkshop() },
            onToggleSound: { [weak self] _ in self?.displays.applySoundSetting() },
            onToggleAudio: { [weak self] enabled in self?.setAudioCapture(enabled) },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onPowerChanged: { [weak self] in
                self?.settings?.reloadPower()
                self?.power?.poll()
            },
            currentItem: { [weak self] in self?.currentItem },
            onSetCanvasFit: { [weak self] item, mode in self?.setCanvasFit(mode, for: item) },
            onAddLocalVideo: { [weak self] in self?.addLocalVideo() },
            onDeleteLocalVideo: { [weak self] item in self?.deleteLocalVideo(item) },
            onIdleFullscreenChanged: { [weak self] in self?.idleFullscreen?.reload() },
            screens: { [weak self] in self?.displays.screensInfo() ?? [] },
            applyTarget: { [weak self] in self?.effectiveTarget },
            onSetTarget: { [weak self] target in
                self?.applyTarget = target
                self?.settings?.reloadProperties()
            },
            onRotationChanged: { [weak self] in self?.rotation?.reload() },
            onQuit: { NSApp.terminate(nil) }
        )
        // 변환이 시작/성공/실패할 때마다 메뉴의 "(변환 중)" 같은 표시를
        // 다시 그린다 — 안 그러면 골랐을 때 한 번 그린 상태로 굳는다.
        displays.onConversionStateChanged = { [weak self] in self?.menuBar?.refreshStates() }
        refreshLibrary()
        restoreSelections()
        let rotation = RotationController(rotate: { [weak self] in self?.rotate() })
        self.rotation = rotation
        rotation.reload()
        // 확인용: 켜자마자 설정 창을 연다(속성 편집기 배치 확인).
        if ProcessInfo.processInfo.environment["WALLFLOW_OPEN_SETTINGS"] != nil {
            showSettings()
        }
        // 확인용: 켜자마자 창작마당 창을 연다(`browse`면 창작마당 탭으로).
        if let open = ProcessInfo.processInfo.environment["WALLFLOW_OPEN_WORKSHOP"] {
            showWorkshop()
            if open == "browse" { workshop?.selectTab(.browse) }
            if let id = ProcessInfo.processInfo.environment["WALLFLOW_WORKSHOP_SELECT"] {
                workshop?.selectItem(id: id)
            }
        }
    }

    /// 지난번에 쓰던 배경화면을 다시 건다: "모든 화면" 배경을 건 뒤 화면별 지정을 덮는다.
    ///
    /// 라이브러리에서 사라졌으면 조용히 넘어간다 — 사용자가 지웠거나 옮긴 것이고,
    /// 그 경우 오류를 띄우는 건 도움이 안 된다.
    private func restoreSelections() {
        defer { menuBar?.refreshStates() }
        let items = (try? library.scan()) ?? []
        if let saved = UserDefaults.standard.string(forKey: Self.lastSelectionKey),
           let item = items.first(where: { $0.id == saved }) {
            try? displays.assign(item, toDisplay: nil)
        }
        let map = DisplaySelectionStore.load()
        for screen in displays.screensInfo() {
            guard let id = map[screen.key], let item = items.first(where: { $0.id == id }) else { continue }
            try? displays.assign(item, toDisplay: screen.id)
        }
        settings?.reloadProperties()
    }

    func applicationWillTerminate(_ notification: Notification) {
        power?.stop()
        idleFullscreen?.stop()
        rotation?.stop()
        displays.stopAll()
    }

    /// 창작마당 창을 띄운다. 이미 떠 있으면 앞으로 가져온다.
    private func showWorkshop() {
        if workshop == nil {
            workshop = WorkshopWindowController(
                installer: installer,
                store: SceneRenderer.propertyStore,
                libraryItems: { [weak self] in (try? self?.library.scan()) ?? [] },
                onApply: { [weak self] item in self?.select(item) },
                currentItemID: { [weak self] in self?.currentItem?.id },
                isItemInUse: { [weak self] id in self?.displays.assignedItemIDs.contains(id) ?? false },
                onLibraryChanged: { [weak self] in self?.refreshLibrary() },
                onPropertiesChanged: { [weak self] id in self?.displays.reload(itemID: id) })
        }
        // 메뉴바 전용 앱이라 창을 띄우려면 앱을 활성화해야 한다.
        NSApp.activate(ignoringOtherApps: true)
        workshop?.showWindow(nil)
        workshop?.window?.makeKeyAndOrderFront(nil)
    }

    /// 소리 듣기는 앱 전체가 하나만 돈다. 화면이 여럿이어도 시스템 소리는 하나다.
    /// 메뉴와 설정 창이 같은 길을 쓴다.
    private func setAudioCapture(_ enabled: Bool) {
        applyAudioCapture()
        menuBar?.refreshStates()
    }

    /// 사용자가 켜 뒀고 **지금 걸린 씬이 소리를 쓸 때만** 듣는다.
    private func applyAudioCapture() {
        if AudioSpectrum.isEnabled, audioNeeded {
            let source = SceneRenderer.audioSource ?? AudioSpectrum()
            SceneRenderer.audioSource = source
            source.start()
        } else {
            SceneRenderer.audioSource?.stop()
        }
    }

    /// 지금 걸린 씬들이 소리를 필요로 하는지. 렌더러가 알려 준다.
    private var audioNeeded = false

    private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                store: SceneRenderer.propertyStore,
                currentItem: { [weak self] in self?.currentItem },
                onPropertiesChanged: { [weak self] id in self?.displays.reload(itemID: id) },
                // 규칙이 바뀌면 다음 5초를 기다리지 않고 바로 다시 판정한다.
                // 메뉴바의 "프레임" 체크 표시도 여기서 바꾼 값을 따라가야 한다.
                onPowerChanged: { [weak self] in
                    self?.power?.poll()
                    self?.menuBar?.refreshStates()
                },
                onSoundChanged: { [weak self] in
                    self?.displays.applySoundSetting()
                    self?.menuBar?.refreshStates()
                },
                onAudioChanged: { [weak self] enabled in self?.setAudioCapture(enabled) },
                onIdleFullscreenChanged: { [weak self] in
                    self?.idleFullscreen?.reload()
                    self?.menuBar?.refreshStates()
                })
        }
        settings?.reloadProperties()
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    /// 라이브러리를 다시 읽고, **걸려 있던 배경이 사라졌으면** 정리한다. 메뉴의 로컬 영상
    /// 삭제와 창작마당 창의 삭제가 모두 여기를 지나므로 한 곳에서 처리된다.
    private func refreshLibrary() {
        // 읽기가 실패했을 때 "전부 사라짐"으로 보면 모든 배경을 내려 버린다 — 그때는 정리하지 않는다.
        guard let items = try? library.scan() else {
            menuBar?.setItems([])
            return
        }
        let present = Set(items.map(\.id))
        for gone in displays.assignedItemIDs.subtracting(present) {
            forgetRemoved(gone, remaining: items)
        }
        menuBar?.setItems(items)
    }

    /// 지운 배경을 걸려 있던 모든 화면에서 내리고(남은 것으로 바꾸거나, 없으면 창을 내림),
    /// 저장된 선택·화면별 지정·자동 바꾸기 빼기 목록·배경별 볼륨에서도 뺀다.
    private func forgetRemoved(_ id: String, remaining: [WallpaperItem]) {
        let replacement = remaining.first { $0.type != .unsupported }
        displays.unassign(itemID: id, replacement: replacement)
        if UserDefaults.standard.string(forKey: Self.lastSelectionKey) == id {
            if let replacement {
                UserDefaults.standard.set(replacement.id, forKey: Self.lastSelectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSelectionKey)
            }
        }
        DisplaySelectionStore.save(DisplaySelection.removing(itemID: id, in: DisplaySelectionStore.load()))
        RotationController.setExcluded(id, false)
        VolumePreferencesStore.clearVolume(for: id)
        settings?.reloadProperties()
    }

    /// 자동으로 바꾸기 한 차례. 화면별 지정이 없으면 기본 배경을 다음으로 바꿔 모든 화면에
    /// 걸고(화면끼리 맞춰 바뀐다), 있으면 화면마다 자기 배경의 다음으로 바꾼다.
    private func rotate() {
        guard let items = try? library.scan() else { return }
        let excluded = RotationController.excluded
        // 열 수 없는 것과 변환이 안 되는 영상(ffmpeg 없음·실패)은 빼 둔다 — 걸면 정지 화면이 된다.
        let candidates = items.filter { item in
            guard item.type != .unsupported, !excluded.contains(item.id) else { return false }
            switch displays.conversionState(for: item) {
            case .ffmpegMissing, .failed: return false
            case .converting, nil: return true
            }
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = candidates.map(\.id)
        let shuffle = RotationController.shuffle
        let next: (String?) -> WallpaperItem? = { current in
            WallpaperRotation.next(after: current, in: ids, shuffle: shuffle,
                                   random: { Int.random(in: 0..<$0) }).flatMap { byID[$0] }
        }
        let screens = displays.screensInfo()
        var map = DisplaySelectionStore.load()
        defer {
            settings?.reloadProperties()
            menuBar?.refreshStates()
        }
        if !screens.contains(where: { map[$0.key] != nil }) {
            guard let item = next(displays.currentItem?.id) else { return }
            try? displays.assign(item, toDisplay: nil)
            UserDefaults.standard.set(item.id, forKey: Self.lastSelectionKey)
            return
        }
        for screen in screens {
            guard let item = next(displays.item(onDisplay: screen.id)?.id) else { continue }
            try? displays.assign(item, toDisplay: screen.id)
            map = DisplaySelection.setting(item.id, forDisplay: screen.key, in: map)
        }
        DisplaySelectionStore.save(map)
    }

    /// 내 동영상 파일을 골라 라이브러리에 추가한다. 여럿 고를 수 있고 마지막 것을 건다.
    private func addLocalVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "추가"
        panel.message = "배경화면으로 쓸 동영상을 고르세요"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        var added: WallpaperItem?
        var failures: [String] = []
        for url in panel.urls {
            do {
                let item = try LocalVideoImporter.importVideo(
                    from: url, title: nil, into: library.root)
                // 썸네일은 실패해도 조용히 넘어간다(webm 등). 미리보기 없이도 뜬다.
                LocalVideoThumbnail.generate(forVideoAt: item.contentURL, into: item.directory)
                added = item
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshLibrary()
        if let added { select(added) }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "일부 동영상을 추가하지 못했습니다"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// 내가 추가한 로컬 영상을 지운다. 창작마당 링크·사용자 폴더는
    /// `LocalVideoImporter.deleteLocal`의 가드가 거부하므로 안전하다.
    private func deleteLocalVideo(_ item: WallpaperItem) {
        let alert = NSAlert()
        alert.messageText = "‘\(item.title)’을(를) 삭제할까요?"
        alert.informativeText = "이 로컬 영상이 라이브러리에서 영구히 지워집니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try LocalVideoImporter.deleteLocal(item, root: library.root)
        } catch {
            let err = NSAlert()
            err.messageText = "삭제하지 못했습니다"
            err.informativeText = error.localizedDescription
            err.runModal()
            return
        }
        // 지운 배경의 배경별 볼륨 설정도 함께 정리한다(어느 화면에도 안 걸려 있었어도).
        VolumePreferencesStore.clearVolume(for: item.id)
        // 걸려 있던 모든 화면에서 내리고 남은 것으로 바꾸는 건 새로고침이 한 곳에서 한다.
        refreshLibrary()
    }

    /// 메뉴의 "화면 맞춤"이 부른다. 저장하고, 지금 그 배경화면을 보여주는
    /// 렌더러 전부에 재시작 없이 바로 적용한다.
    private func setCanvasFit(_ mode: CanvasFit.Mode, for item: WallpaperItem) {
        CanvasFitPreferencesStore.setMode(mode, for: item.id)
        displays.applyCanvasFit(mode, toWallpaperID: item.id)
        menuBar?.refreshStates()
    }

    /// 고른 배경을 적용 대상(모든 화면 또는 한 화면)에 걸고 저장한다.
    /// "모든 화면"이면 지금 연결된 화면의 화면별 지정을 지운다(꺼진 모니터 설정은 남긴다).
    private func select(_ item: WallpaperItem) {
        // displays.currentItem은 toDisplay가 nil이면 assign이 실패해도 이미
        // 바뀌어 있다 — 메뉴의 "화면 맞춤" 체크 표시·활성 상태가 새 배경화면
        // 것을 보게 성공·실패 양쪽에서 갱신한다.
        defer { menuBar?.refreshStates() }
        let target = effectiveTarget
        do {
            try displays.assign(item, toDisplay: target)
            let screens = displays.screensInfo()
            if let target, let key = screens.first(where: { $0.id == target })?.key {
                DisplaySelectionStore.save(
                    DisplaySelection.setting(item.id, forDisplay: key, in: DisplaySelectionStore.load()))
            } else {
                UserDefaults.standard.set(item.id, forKey: Self.lastSelectionKey)
                DisplaySelectionStore.save(DisplaySelection.clearing(
                    displays: screens.map(\.key), in: DisplaySelectionStore.load()))
            }
            // 직접 골랐으면 자동으로 바꾸기는 지금부터 다시 센다.
            RotationController.markChanged()
            // 설정 창이 열려 있으면 속성 탭을 새 배경화면 것으로 바꾼다.
            settings?.reloadProperties()
        } catch {
            // 배경화면은 항상 켜져 있어야 한다. 실패해도 앱을 죽이지 않는다.
            // 다만 **이유는 반드시 남긴다** — 조용히 검은 화면이 되면 사용자는
            // 자기가 받은 것이 왜 안 뜨는지 알 수 없다.
            if case RendererError.unopenable(let reason) = error {
                FileHandle.standardError.write(Data(
                    "\(item.title): 이 배경화면은 열 수 없다 — \(reason)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "\(item.title): 배경화면 적용 실패: \(error)\n".utf8))
            }
        }
    }
}
