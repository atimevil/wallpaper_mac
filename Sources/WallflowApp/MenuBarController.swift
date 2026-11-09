import AppKit
import WallflowKit

/// 메뉴바 아이콘과 배경화면 목록 메뉴.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onSelect: (WallpaperItem) -> Void
    /// webm/mkv 변환 대상의 지금 상태(ffmpeg 없음/변환 중/실패). 그런 항목이
    /// 아니거나 평소와 다를 게 없으면(캐시 있음/아직 시도 전) nil을 준다.
    private let conversionState: (WallpaperItem) -> VideoConverter.VideoConversionState?
    private let onRefresh: () -> Void
    private let onBrowseWorkshop: () -> Void
    private let onToggleSound: (Bool) -> Void
    private let onToggleAudio: (Bool) -> Void
    private let onOpenSettings: () -> Void
    private let onPowerChanged: () -> Void
    private let onQuit: () -> Void
    /// 지금 모든 화면에 걸린 배경화면. "화면 맞춤" 메뉴가 무엇에 적용할지 정한다.
    private let currentItem: () -> WallpaperItem?
    private let onSetCanvasFit: (WallpaperItem, CanvasFit.Mode) -> Void
    private let onAddLocalVideo: () -> Void
    private let onDeleteLocalVideo: (WallpaperItem) -> Void
    /// 유휴 전체화면(감상 모드) 토글이 바뀌면 컨트롤러를 다시 걸어야 한다.
    private let onIdleFullscreenChanged: () -> Void
    /// 화면이 둘 이상일 때 "적용할 화면" 메뉴에 쓴다.
    private let screens: () -> [DisplayManager.ScreenInfo]
    /// 배경을 고르면 걸 대상. nil이면 모든 화면.
    private let applyTarget: () -> CGDirectDisplayID?
    private let onSetTarget: (CGDirectDisplayID?) -> Void
    /// 자동으로 바꾸기 설정이 바뀌면 컨트롤러를 다시 걸어야 한다.
    private let onRotationChanged: () -> Void
    /// "다음 배경으로" — 자동으로 바꾸기와 같은 규칙(빼기·무작위)으로 지금 한 번 넘긴다.
    private let onNextWallpaper: () -> Void
    private var items: [WallpaperItem] = []

    /// "화면 맞춤" 메뉴 항목의 이름과 값. 채우기가 기본이라 맨 앞이다.
    private static let canvasFitChoices: [(String, CanvasFit.Mode)] = [
        ("채우기", .cover), ("전체 보기", .contain), ("늘이기", .stretch),
    ]

    init(
        onSelect: @escaping (WallpaperItem) -> Void,
        conversionState: @escaping (WallpaperItem) -> VideoConverter.VideoConversionState?,
        onRefresh: @escaping () -> Void,
        onBrowseWorkshop: @escaping () -> Void,
        onToggleSound: @escaping (Bool) -> Void,
        onToggleAudio: @escaping (Bool) -> Void,
        onOpenSettings: @escaping () -> Void,
        onPowerChanged: @escaping () -> Void,
        currentItem: @escaping () -> WallpaperItem?,
        onSetCanvasFit: @escaping (WallpaperItem, CanvasFit.Mode) -> Void,
        onAddLocalVideo: @escaping () -> Void,
        onDeleteLocalVideo: @escaping (WallpaperItem) -> Void,
        onIdleFullscreenChanged: @escaping () -> Void,
        screens: @escaping () -> [DisplayManager.ScreenInfo],
        applyTarget: @escaping () -> CGDirectDisplayID?,
        onSetTarget: @escaping (CGDirectDisplayID?) -> Void,
        onRotationChanged: @escaping () -> Void,
        onNextWallpaper: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggleSound = onToggleSound
        self.onToggleAudio = onToggleAudio
        self.onOpenSettings = onOpenSettings
        self.onPowerChanged = onPowerChanged
        self.onSelect = onSelect
        self.conversionState = conversionState
        self.onRefresh = onRefresh
        self.onBrowseWorkshop = onBrowseWorkshop
        self.currentItem = currentItem
        self.onSetCanvasFit = onSetCanvasFit
        self.onAddLocalVideo = onAddLocalVideo
        self.onDeleteLocalVideo = onDeleteLocalVideo
        self.onIdleFullscreenChanged = onIdleFullscreenChanged
        self.screens = screens
        self.applyTarget = applyTarget
        self.onSetTarget = onSetTarget
        self.onRotationChanged = onRotationChanged
        self.onNextWallpaper = onNextWallpaper
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallflow"
        )
        rebuildMenu()
    }

    func setItems(_ items: [WallpaperItem]) {
        self.items = items
        rebuildMenu()
    }

    /// 설정 창에서 값이 바뀌면 메뉴의 체크 표시도 따라가야 한다.
    func refreshStates() { rebuildMenu() }

    /// 목록이 이보다 길면 "모든 배경화면" 하위 메뉴로 옮긴다 — 창작마당에서 받을수록 메인 메뉴가
    /// 끝없이 길어지면 아래쪽 설정 항목을 찾기 어렵다.
    private static let inlineListLimit = 12

    /// 메뉴는 고르는 순서대로 묶는다: 적용할 화면 → 배경화면(목록·다음) → 지금 배경 → 화면 →
    /// 소리·재생 → 넣기·찾기 → 앱. (macOS 메뉴바 앱 관례 — 섹션 머리로 무리를 나눈다.)
    private func rebuildMenu() {
        let menu = NSMenu()
        // 항목을 직접 활성/비활성 하려면 자동 활성화를 꺼야 한다.
        menu.autoenablesItems = false
        // 화면 수만큼 UUID를 조회하므로 한 번만 묻는다.
        let current = currentItem()

        // 화면이 둘 이상일 때만: 목록에서 고른 배경을 어느 화면에 걸지. 고른 대상을
        // 제목에 보여 준다 — 숨은 상태로 두면 "모든 화면"에 걸려던 게 한 화면에만 간다.
        let screenList = screens()
        if screenList.count > 1 {
            let target = applyTarget()
            let targetName = screenList.first { $0.id == target }?.name ?? "모든 화면"
            let targetItem = NSMenuItem(
                title: "적용할 화면: \(targetName)", action: nil, keyEquivalent: "")
            let targetMenu = NSMenu()
            let all = NSMenuItem(title: "모든 화면", action: #selector(setTarget(_:)), keyEquivalent: "")
            all.target = self
            all.state = target == nil ? .on : .off
            targetMenu.addItem(all)
            targetMenu.addItem(.separator())
            for screen in screenList {
                let entry = NSMenuItem(
                    title: screen.name, action: #selector(setTarget(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = NSNumber(value: screen.id)
                entry.state = target == screen.id ? .on : .off
                targetMenu.addItem(entry)
            }
            targetItem.submenu = targetMenu
            menu.addItem(targetItem)
            menu.addItem(.separator())
        }

        // ── 배경화면
        menu.addItem(.sectionHeader(title: "배경화면"))
        if items.isEmpty {
            let empty = NSMenuItem(title: "배경화면 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if items.count > Self.inlineListLimit {
            // 지금 것은 위에 그대로 두고, 전부는 하위 메뉴로.
            if let current, let index = items.firstIndex(where: { $0.id == current.id }) {
                menu.addItem(wallpaperMenuItem(index: index, currentID: current.id))
            }
            let all = NSMenuItem(title: "모든 배경화면 (\(items.count))", action: nil, keyEquivalent: "")
            let list = NSMenu()
            list.autoenablesItems = false
            for index in items.indices {
                list.addItem(wallpaperMenuItem(index: index, currentID: current?.id))
            }
            all.submenu = list
            menu.addItem(all)
        } else {
            for index in items.indices {
                menu.addItem(wallpaperMenuItem(index: index, currentID: current?.id))
            }
        }
        // 자동으로 돌아가는 내용에는 사람이 넘기는 길도 있어야 한다(자동 바꾸기를 켜지 않아도 쓴다).
        let next = NSMenuItem(title: "다음 배경으로", action: #selector(nextWallpaper), keyEquivalent: "")
        next.target = self
        next.isEnabled = items.filter { $0.type != .unsupported }.count > 1
        menu.addItem(next)

        // ── 지금 배경: 지금 걸린 배경화면에만 저장·적용되는 것
        if let current {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "지금 배경 — \(Self.shortTitle(current.title, limit: 24))"))

            // 씬마다 소리 크기가 제각각이라 켜고 끄는 것만으로는 부족하다.
            // 씬이 정한 볼륨에 곱해지므로, 씬 안의 균형은 그대로 남는다.
            let volumeItem = NSMenuItem(title: "소리 크기", action: nil, keyEquivalent: "")
            let volumeMenu = NSMenu()
            let volume = VolumePreferencesStore.displayVolume(for: current)
            for percent in [0, 25, 50, 75, 100] {
                let entry = NSMenuItem(
                    title: "\(percent)%", action: #selector(setVolume), keyEquivalent: "")
                entry.target = self
                entry.tag = percent
                // 저장된 값이 목록에 없는 값일 수도 있다. 가장 가까운 것에 표시한다 —
                // 아무 데도 표시가 없으면 지금 크기를 알 수 없다.
                entry.state = abs(volume * 100 - Double(percent)) < 12.5 ? .on : .off
                volumeMenu.addItem(entry)
            }
            volumeItem.submenu = volumeMenu
            menu.addItem(volumeItem)

            // 화면 맞춤. 씬이 아니면(비디오·웹) 실제로 아무것도 안 바뀌므로 비활성화한다.
            let fitItem = NSMenuItem(title: "화면 맞춤", action: nil, keyEquivalent: "")
            let fitMenu = NSMenu()
            let currentFit = CanvasFitPreferencesStore.mode(for: current.id)
            for (label, mode) in Self.canvasFitChoices {
                let entry = NSMenuItem(
                    title: label, action: #selector(setCanvasFit(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = mode
                entry.state = currentFit == mode ? .on : .off
                fitMenu.addItem(entry)
            }
            fitItem.submenu = fitMenu
            fitItem.isEnabled = current.type == .scene
            menu.addItem(fitItem)

            let exclude = NSMenuItem(
                title: "자동으로 바꾸기에서 빼기", action: #selector(toggleRotationExcluded(_:)),
                keyEquivalent: "")
            exclude.target = self
            exclude.state = RotationController.excluded.contains(current.id) ? .on : .off
            menu.addItem(exclude)

            // 내가 추가한 로컬 영상이면 지우는 길을 둔다. 창작마당 항목은 창작마당 창에서 지운다.
            if LocalVideoImporter.isLocal(current) {
                let delete = NSMenuItem(
                    title: "이 로컬 영상 삭제…", action: #selector(deleteLocalVideo), keyEquivalent: "")
                delete.target = self
                menu.addItem(delete)
            }
        }

        // ── 화면
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "화면"))
        // 자동으로 바꾸기: 간격(하나만 체크), 무작위 순서.
        let rotation = NSMenuItem(title: "자동으로 바꾸기", action: nil, keyEquivalent: "")
        let rotationMenu = NSMenu()
        let interval = RotationController.interval
        for (label, seconds) in RotationController.choices {
            let entry = NSMenuItem(
                title: label, action: #selector(setRotationInterval(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(seconds)
            entry.state = Int(interval) == Int(seconds) ? .on : .off
            rotationMenu.addItem(entry)
        }
        rotationMenu.addItem(.separator())
        let shuffle = NSMenuItem(
            title: "무작위 순서", action: #selector(toggleRotationShuffle(_:)), keyEquivalent: "")
        shuffle.target = self
        shuffle.state = RotationController.shuffle ? .on : .off
        rotationMenu.addItem(shuffle)
        rotation.submenu = rotationMenu
        // 켜져 있으면 제목에 간격을 보인다 — 왜 배경이 저절로 바뀌는지 메뉴만 봐도 알게.
        if let label = RotationController.choices.first(where: { $0.1 == interval && interval > 0 })?.0 {
            rotation.title = "자동으로 바꾸기: \(label)"
        }
        menu.addItem(rotation)

        // 유휴 전체화면(감상 모드). 시간은 설정 창에서 고른다.
        let idleFull = NSMenuItem(
            title: "유휴 시 전체화면", action: #selector(toggleIdleFullscreen), keyEquivalent: "")
        idleFull.target = self
        idleFull.state = IdleFullscreenController.isEnabled ? .on : .off
        idleFull.toolTip = "자리를 비우면 배경화면을 전체화면으로 보여 줍니다. "
            + "마우스·키를 움직이면 사라집니다. 시간은 설정에서 바꿉니다."
        menu.addItem(idleFull)

        // 바탕화면 아이콘 숨기기. 실제 파인더 설정을 읽어 표시한다.
        let hideIcons = NSMenuItem(
            title: "바탕화면 아이콘 숨기기", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        hideIcons.target = self
        hideIcons.state = DesktopIcons.isHidden ? .on : .off
        hideIcons.toolTip = "파인더를 잠깐 다시 띄웁니다(열린 파인더 창이 닫혔다 열립니다)."
        menu.addItem(hideIcons)

        // ── 소리·재생
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "소리·재생"))
        let sound = NSMenuItem(
            title: "소리", action: #selector(toggleSound), keyEquivalent: "s")
        sound.target = self
        // 배경화면이 로그인할 때마다 소리를 내면 곤란하므로 기본은 꺼짐이다.
        sound.state = UserDefaults.standard.bool(forKey: Self.soundKey) ? .on : .off
        menu.addItem(sound)

        // 오디오 반응. 켜면 시스템 소리를 듣고 macOS가 화면 녹화 권한을 묻는다 —
        // 시스템 오디오 캡처가 그 권한 아래 있다. 기본은 꺼짐이다.
        let audio = NSMenuItem(
            title: "소리에 반응하기", action: #selector(toggleAudio), keyEquivalent: "")
        audio.target = self
        audio.state = AudioSpectrum.isEnabled ? .on : .off
        menu.addItem(audio)

        // 프레임. 전원 연결 시와 배터리·저전력일 때를 따로 고른다(WE 성능 설정의
        // 배터리 규칙처럼). 설정 창까지 열지 않고 바로 바꾸는 자리다.
        let power = PowerPreferencesStore.load()
        let fpsItem = NSMenuItem(title: "프레임", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        fpsMenu.addItem(NSMenuItem.sectionHeader(title: "전원 연결"))
        for fps in PowerPreferences.allowedFPS {
            let entry = NSMenuItem(title: "\(fps)", action: #selector(setFPS), keyEquivalent: "")
            entry.target = self
            entry.tag = fps
            entry.state = power.targetFPS == fps ? .on : .off
            fpsMenu.addItem(entry)
        }
        fpsMenu.addItem(.separator())
        fpsMenu.addItem(NSMenuItem.sectionHeader(title: "배터리·저전력"))
        for (label, fps) in PowerPreferencesStore.batteryChoices {
            let entry = NSMenuItem(title: label, action: #selector(setBatteryFPS), keyEquivalent: "")
            entry.target = self
            entry.tag = fps
            entry.state = power.batteryFPS == fps ? .on : .off
            fpsMenu.addItem(entry)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        // ── 넣기·찾기
        menu.addItem(.separator())
        // 내 동영상 파일을 바로 배경화면으로 추가한다(창작마당을 거치지 않는다).
        let addLocal = NSMenuItem(
            title: "동영상 추가…", action: #selector(addLocalVideo), keyEquivalent: "")
        addLocal.target = self
        menu.addItem(addLocal)
        let browse = NSMenuItem(
            title: "창작마당 둘러보기…", action: #selector(browseWorkshop), keyEquivalent: "w")
        browse.target = self
        menu.addItem(browse)
        let refresh = NSMenuItem(title: "라이브러리 새로고침", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        // ── 앱
        menu.addItem(.separator())
        let login = NSMenuItem(
            title: "로그인할 때 시작", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let settings = NSMenuItem(
            title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// 목록의 배경화면 한 줄. 이름 뒤에 종류를 한국어로(씬·비디오·웹) 붙인다. 열 수 없거나
    /// 변환이 필요한 것은 그렇다고 적는다 — 목록에서 빼면 왜 안 보이는지, 표시 없이 두면
    /// 골랐을 때 왜 안 바뀌는지 알 수 없다. 긴 이름은 줄이고 전체는 도움말로 보인다.
    private func wallpaperMenuItem(index: Int, currentID: String?) -> NSMenuItem {
        let item = items[index]
        var kind = Self.kindLabel(item.type)
        var reason = item.unsupportedReason
        if reason != nil { kind = "열 수 없음" }
        // webm/mkv 변환 대상은 .unsupported가 아니라 .video라 위 분기를
        // 안 탄다 — ffmpeg 없음/변환 중/실패는 여기서 따로 물어 보여준다.
        if let state = conversionState(item) {
            kind = VideoConverter.menuLabelSuffix(for: state)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            reason = VideoConverter.menuTooltip(for: state)
        }
        let name = Self.shortTitle(item.title, limit: 36)
        let menuItem = NSMenuItem(
            title: "\(name)  ·  \(kind)", action: #selector(select(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = index
        // 변환 대상은 ffmpeg 없음/변환 중/실패여도 .video라 고를 수는 있다 —
        // 골라야 변환이 시작되므로 막으면 안 된다.
        menuItem.isEnabled = item.type != .unsupported
        let tip = [name == item.title ? nil : item.title, reason].compactMap { $0 }
        menuItem.toolTip = tip.isEmpty ? nil : tip.joined(separator: "\n")
        // 지금 대상에 걸린 배경에 체크 — 화면마다 다를 수 있어 무엇이 걸렸는지 보여야 한다.
        menuItem.state = item.id == currentID ? .on : .off
        return menuItem
    }

    private static func kindLabel(_ type: WallpaperType) -> String {
        switch type {
        case .scene: return "씬"
        case .video: return "비디오"
        case .web: return "웹"
        case .unsupported: return "열 수 없음"
        }
    }

    /// 메뉴 폭이 제목 길이를 따라 넓어지므로 긴 이름(중국어·일본어 제목이 흔하다)은 줄인다.
    private static func shortTitle(_ title: String, limit: Int) -> String {
        title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
    }

    /// 메뉴가 열리기 직전에, 앱 밖에서 바뀔 수 있는 체크 표시를 실제 상태로 다시
    /// 맞춘다. 메뉴는 앱 안 동작 때만 다시 만들어져서, 터미널·다른 앱·시스템 설정에서
    /// 바꾼 바탕화면 아이콘·로그인 항목은 안 그러면 옛 표시로 남는다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleDesktopIcons(_:)): item.state = DesktopIcons.isHidden ? .on : .off
            case #selector(toggleLogin(_:)): item.state = LoginItem.isEnabled ? .on : .off
            default: break
            }
        }
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
        // 소리 크기 항목의 켬/끔 표시도 따라가야 한다. 메뉴를 다시 만든다.
        rebuildMenu()
        onToggleSound(enabled)
    }

    /// 켜기 전에 무엇이 일어나는지 말한다. 배경화면이 소리를 듣기 시작하는
    /// 것은 사용자가 알고 고를 일이지, 조용히 켜질 일이 아니다.
    /// 메뉴와 설정 창이 같은 확인창을 쓴다.
    static func confirmAudioCapture() -> Bool {
        let alert = NSAlert()
        alert.messageText = "소리에 반응하려면 시스템 소리를 들어야 합니다"
        alert.informativeText = """
            macOS가 화면 녹화 권한을 한 번 묻습니다. 시스템 오디오 캡처가             그 권한 아래 있어서입니다.

            Wallflow는 화면을 읽지 않고 소리만 받습니다. 받은 소리는 곧바로             주파수 크기로 바뀌어 그리는 데 쓰이고 버려집니다 — 저장하지도,             어디로 보내지도 않습니다.
            """
        alert.addButton(withTitle: "켜기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func toggleAudio(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        if enabled, !Self.confirmAudioCapture() { return }
        UserDefaults.standard.set(enabled, forKey: AudioSpectrum.enabledKey)
        sender.state = enabled ? .on : .off
        onToggleAudio(enabled)
    }

    @objc private func toggleDesktopIcons(_ sender: NSMenuItem) {
        DesktopIcons.setHidden(sender.state != .on)
        sender.state = DesktopIcons.isHidden ? .on : .off
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        onSetTarget((sender.representedObject as? NSNumber)?.uint32Value)
        rebuildMenu()
    }

    @objc private func nextWallpaper() { onNextWallpaper() }

    @objc private func setRotationInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: RotationController.intervalKey)
        // 켜는 순간부터 센다 — 예전 기준 시각이 남아 있으면 켜자마자 바뀐다.
        RotationController.markChanged()
        onRotationChanged()
        rebuildMenu()
    }

    @objc private func toggleRotationShuffle(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.state != .on, forKey: RotationController.shuffleKey)
        rebuildMenu()
    }

    @objc private func toggleRotationExcluded(_ sender: NSMenuItem) {
        guard let current = currentItem() else { return }
        RotationController.setExcluded(current.id, sender.state != .on)
        rebuildMenu()
    }

    @objc private func toggleIdleFullscreen(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        UserDefaults.standard.set(enabled, forKey: IdleFullscreenController.enabledKey)
        sender.state = enabled ? .on : .off
        onIdleFullscreenChanged()
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func setVolume(_ sender: NSMenuItem) {
        let volume = Double(sender.tag) / 100
        // 지금 걸린 배경화면에 저장한다(배경마다 따로). 걸린 게 없으면 전역 기본에.
        if let item = currentItem() {
            VolumePreferencesStore.setVolume(volume, for: item.id)
        } else {
            UserDefaults.standard.set(volume, forKey: SceneRenderer.volumeKey)
        }
        rebuildMenu()
        // 소리 설정을 다시 적용하는 경로가 이것뿐이다. 켬/끔과 같은 길을 쓴다.
        onToggleSound(UserDefaults.standard.bool(forKey: Self.soundKey))
    }

    @objc private func setFPS(_ sender: NSMenuItem) {
        var prefs = PowerPreferencesStore.load()
        prefs.targetFPS = sender.tag
        PowerPreferencesStore.save(prefs)
        rebuildMenu()
        onPowerChanged()
    }

    @objc private func setBatteryFPS(_ sender: NSMenuItem) {
        var prefs = PowerPreferencesStore.load()
        prefs.batteryFPS = sender.tag
        PowerPreferencesStore.save(prefs)
        rebuildMenu()
        onPowerChanged()
    }

    @objc private func setCanvasFit(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? CanvasFit.Mode,
              let item = currentItem() else { return }
        onSetCanvasFit(item, mode)
        rebuildMenu()
    }

    @objc private func browseWorkshop() { onBrowseWorkshop() }

    @objc private func addLocalVideo() { onAddLocalVideo() }

    @objc private func deleteLocalVideo() {
        guard let current = currentItem(), LocalVideoImporter.isLocal(current) else { return }
        onDeleteLocalVideo(current)
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func refresh() { onRefresh() }
    @objc private func quit() { onQuit() }
}
