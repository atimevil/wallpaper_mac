import AppKit
import WallflowKit

/// 위가 원점인 뷰. `NSScrollView`의 문서 뷰는 기본이 **아래 원점**이라 내용이
/// 창 바닥에 붙고 스크롤이 끝에서 시작한다 — 첫 줄이 잘려 보인다. 뒤집으면
/// 글처럼 위에서 아래로 흐른다.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 설정 창. 두 탭이다 — 앱 전체 규칙(일반)과, 지금 걸린 배경화면이 열어 둔
/// 손잡이(배경화면 속성). 실물 Wallpaper Engine의 설정과 오른쪽 속성 패널에
/// 해당한다. 지금까지는 전부 고정값이라 사용자가 색 하나 못 바꿨다.
@MainActor
final class SettingsWindowController: NSWindowController {
    static var current: SettingsWindowController?

    private let store: UserPropertyStore
    private let currentItem: () -> WallpaperItem?
    /// 속성이 바뀌면 배경화면을 다시 연다. 값은 씬을 읽을 때 얹히므로 다시
    /// 읽어야 먹는다.
    private let onPropertiesChanged: (String) -> Void
    private let onPowerChanged: () -> Void
    private let onSoundChanged: () -> Void
    private let onAudioChanged: (Bool) -> Void
    private let onIdleFullscreenChanged: () -> Void
    /// 자동으로 바꾸기·바탕화면 아이콘처럼 메뉴와 같이 쓰는 값이 바뀌면 메뉴·컨트롤러를 다시 건다.
    private let onDisplayOptionsChanged: () -> Void

    private let tabs = NSTabView()
    private lazy var propertyEditor = PropertyEditorView(store: store, onChanged: onPropertiesChanged)

    init(store: UserPropertyStore,
         currentItem: @escaping () -> WallpaperItem?,
         onPropertiesChanged: @escaping (String) -> Void,
         onPowerChanged: @escaping () -> Void,
         onSoundChanged: @escaping () -> Void,
         onAudioChanged: @escaping (Bool) -> Void,
         onIdleFullscreenChanged: @escaping () -> Void,
         onDisplayOptionsChanged: @escaping () -> Void) {
        self.store = store
        self.currentItem = currentItem
        self.onPropertiesChanged = onPropertiesChanged
        self.onPowerChanged = onPowerChanged
        self.onSoundChanged = onSoundChanged
        self.onAudioChanged = onAudioChanged
        self.onIdleFullscreenChanged = onIdleFullscreenChanged
        self.onDisplayOptionsChanged = onDisplayOptionsChanged
        let window = UtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 730),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Wallflow 설정"
        window.center()
        super.init(window: window)
        window.contentView = makeContent()
        Self.current = self
        // 메뉴바에서 바꾼 값(소리·자동 바꾸기·감상 모드 등)이 열린 창에도 바로 보이게 한다.
        // 안 그러면 여기 남은 옛 값이 다음 변경 때 메뉴의 선택을 덮어쓴다.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadStates() }
        }
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    /// 배경화면이 바뀌었을 때 속성 탭을 다시 채운다.
    func reloadProperties() {
        propertyEditor.show(item: currentItem())
        // 배경화면이 바뀌면 "지금 배경 크기"도 그 배경 값으로(배경마다 따로다).
        reloadStates()
    }

    /// 메뉴바에서 바꾼 전력 규칙을 다시 읽는다(AppCoordinator가 부른다).
    func reloadPower() { reloadStates() }

    /// 모든 컨트롤을 저장된 값으로 맞춘다. 동작(action)은 일으키지 않는다.
    func reloadStates() {
        let prefs = PowerPreferencesStore.load()
        occludedBox?.state = prefs.pauseWhenOccluded ? .on : .off
        fullscreenBox?.state = prefs.pauseInFullscreen ? .on : .off
        Self.select(idlePopup, tag: Int(prefs.idlePauseSeconds), fallback: 0)
        fpsPopup.selectItem(withTag: prefs.targetFPS)
        batteryPopup.selectItem(withTag: prefs.batteryFPS)
        soundBox?.state = UserDefaults.standard.bool(forKey: MenuBarController.soundKey) ? .on : .off
        audioBox?.state = AudioSpectrum.isEnabled ? .on : .off
        loginBox?.state = LoginItem.isEnabled ? .on : .off
        let idleFullscreen = IdleFullscreenController.isEnabled
        idleFullscreenBox?.state = idleFullscreen ? .on : .off
        Self.select(idleFullscreenPopup, tag: Int(IdleFullscreenController.thresholdSeconds), fallback: 1)
        // 감상 모드를 꺼 두면 기다릴 시간은 뜻이 없다 — 쓸 수 있어 보이면 헷갈린다.
        idleFullscreenPopup.isEnabled = idleFullscreen
        Self.select(rotationPopup, tag: Int(RotationController.interval), fallback: 0)
        shuffleBox?.state = RotationController.shuffle ? .on : .off
        desktopIconsBox?.state = DesktopIcons.isHidden ? .on : .off
        let item = currentItem()
        volumeSlider.doubleValue = VolumePreferencesStore.displayVolume(for: item)
        updateVolumeLabels(for: item)
    }

    /// 저장값이 선택지에 없으면(손으로 고친 값 등) `selectItem(withTag:)`가 선택을 비워 칸이 빈다 —
    /// 그때는 기본 선택지를 보인다. 이 상태로 다른 값을 바꿔도 -1이 저장되지 않는다.
    private static func select(_ popup: NSPopUpButton, tag: Int, fallback: Int) {
        popup.selectItem(withTag: tag)
        if popup.indexOfSelectedItem < 0 { popup.selectItem(at: fallback) }
    }

    /// "지금 배경 크기"의 % 값과, 어느 배경에 적용되는지 알려 주는 도움말.
    private func updateVolumeLabels(for item: WallpaperItem?) {
        volumeValueLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
        if let item {
            let note = item.type == .video ? " 비디오는 크기를 준 것만 소리를 냅니다." : ""
            volumeHelpLabel.stringValue = "‘\(item.title)’에만 적용됩니다.\(note)"
        } else {
            volumeHelpLabel.stringValue = "배경화면을 고르면 그 배경에 적용됩니다."
        }
    }

    // MARK: - 화면

    private func makeContent() -> NSView {
        let general = NSTabViewItem(identifier: "general")
        general.label = "일반"
        general.view = makeGeneralTab()
        let props = NSTabViewItem(identifier: "properties")
        props.label = "배경화면 속성"
        props.view = makePropertiesTab()
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(props)
        return tabs
    }

    /// 일반 탭. 왼쪽 열은 오른쪽 정렬한 라벨, 오른쪽 열은 컨트롤 — 맥 설정 양식처럼 컨트롤이
    /// 한 줄로 맞아 훑기 쉽다. 체크상자는 라벨 없이 오른쪽 열에, 설명은 그 아래 작은 회색 글로.
    private func makeGeneralTab() -> NSView {
        let prefs = PowerPreferencesStore.load()
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        var firstHeader = true

        func header(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: 13)
            let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.cell(at: 0).xPlacement = .leading
            row.topPadding = firstHeader ? 0 : 14
            firstHeader = false
        }
        func row(_ label: String?, _ view: NSView) {
            let left: NSView = label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
            grid.addRow(with: [left, view])
        }
        func check(_ title: String, on: Bool, _ action: Selector) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: self, action: action)
            box.state = on ? .on : .off
            row(nil, box)
            return box
        }
        @discardableResult
        func help(_ text: String, label: NSTextField? = nil) -> NSTextField {
            let field = label ?? NSTextField(wrappingLabelWithString: text)
            field.stringValue = text
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            field.preferredMaxLayoutWidth = 320
            grid.addRow(with: [NSGridCell.emptyContentView, field]).topPadding = -4
            return field
        }
        func popup(_ popup: NSPopUpButton, _ choices: [(String, Int)], selected: Int, _ action: Selector) {
            for (title, tag) in choices {
                popup.addItem(withTitle: title)
                popup.lastItem?.tag = tag
            }
            popup.selectItem(withTag: selected)
            if popup.indexOfSelectedItem < 0 { popup.selectItem(at: 0) }
            popup.target = self
            popup.action = action
        }

        header("배경화면")
        popup(rotationPopup, RotationController.choices.map { ($0.0, Int($0.1)) },
              selected: Int(RotationController.interval), #selector(rotationIntervalChanged))
        row("자동으로 바꾸기:", rotationPopup)
        shuffleBox = check("무작위 순서", on: RotationController.shuffle, #selector(rotationShuffleChanged))
        desktopIconsBox = check("바탕화면 아이콘 숨기기", on: DesktopIcons.isHidden,
                                #selector(desktopIconsChanged))
        help("켜고 끌 때 파인더가 한 번 다시 뜹니다.")

        header("감상 모드")
        idleFullscreenBox = check(
            "자리를 비우면 배경을 전체화면으로 보여 주기",
            on: IdleFullscreenController.isEnabled, #selector(idleFullscreenChanged))
        popup(idleFullscreenPopup, Self.idleFullscreenChoices.map { ($0.0, Int($0.1)) },
              selected: Int(IdleFullscreenController.thresholdSeconds), #selector(idleFullscreenChanged))
        if idleFullscreenPopup.indexOfSelectedItem == 0,
           Int(IdleFullscreenController.thresholdSeconds) != Int(Self.idleFullscreenChoices[0].1) {
            idleFullscreenPopup.selectItem(at: 1)
        }
        idleFullscreenPopup.isEnabled = IdleFullscreenController.isEnabled
        row("기다릴 시간:", idleFullscreenPopup)
        help("마우스·키를 움직이면 바로 사라집니다. 다른 앱에서 영상을 보는 동안에는 띄우지 않습니다.")

        header("소리")
        soundBox = check("배경화면 소리 켜기",
                         on: UserDefaults.standard.bool(forKey: MenuBarController.soundKey),
                         #selector(soundChanged))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = VolumePreferencesStore.displayVolume(for: currentItem())
        volumeSlider.target = self
        volumeSlider.action = #selector(soundChanged)
        volumeSlider.setAccessibilityLabel("지금 배경 소리 크기")
        volumeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let volumeRow = NSStackView(views: [volumeSlider, volumeValueLabel])
        volumeRow.orientation = .horizontal
        row("지금 배경 크기:", volumeRow)
        help("", label: volumeHelpLabel)
        updateVolumeLabels(for: currentItem())
        audioBox = check("소리에 반응하기", on: AudioSpectrum.isEnabled, #selector(audioChanged))
        help("시스템 소리를 듣습니다. 처음 켤 때 화면 녹화 권한을 묻습니다.")

        header("재생·전력")
        occludedBox = check("다른 창에 완전히 가려지면 멈춤", on: prefs.pauseWhenOccluded,
                            #selector(powerChanged))
        fullscreenBox = check("전체화면 앱이 뜨면 멈춤", on: prefs.pauseInFullscreen,
                              #selector(powerChanged))
        popup(idlePopup, Self.idleChoices.map { ($0.0, Int($0.1)) },
              selected: Int(prefs.idlePauseSeconds), #selector(powerChanged))
        row("입력이 없으면 멈춤:", idlePopup)
        popup(fpsPopup, PowerPreferences.allowedFPS.map { ("\($0)", $0) },
              selected: prefs.targetFPS, #selector(powerChanged))
        row("프레임(전원 연결):", fpsPopup)
        popup(batteryPopup, PowerPreferencesStore.batteryChoices.map { ($0.0, $0.1) },
              selected: prefs.batteryFPS, #selector(powerChanged))
        row("배터리·저전력일 때:", batteryPopup)

        header("시작")
        loginBox = check("로그인할 때 시작", on: LoginItem.isEnabled, #selector(loginChanged))

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])
        return Self.scrolling(container)
    }

    /// 내용을 위에서부터 흐르는 스크롤 뷰에 담는다.
    private static func scrolling(_ content: NSView) -> NSScrollView {
        let host = FlippedView()
        host.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        let scroll = NSScrollView()
        scroll.documentView = host
        scroll.hasVerticalScroller = true
        // 내용이 넘칠 때만 보인다 — 늘 보이면 빈 막대 자리가 덜 만든 화면처럼 보인다.
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func makePropertiesTab() -> NSView {
        Self.scrolling(propertyEditor)
    }

    // MARK: - 반응

    private var occludedBox: NSButton?
    private var fullscreenBox: NSButton?
    private var soundBox: NSButton?
    private var audioBox: NSButton?
    private var loginBox: NSButton?
    private var idleFullscreenBox: NSButton?
    private let idleFullscreenPopup = NSPopUpButton()
    private let idlePopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let batteryPopup = NSPopUpButton()
    private let volumeSlider = NSSlider()
    private let volumeValueLabel = NSTextField(labelWithString: "")
    private let volumeHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let rotationPopup = NSPopUpButton()
    private var shuffleBox: NSButton?
    private var desktopIconsBox: NSButton?
    static let idleChoices: [(String, TimeInterval)] = [
        ("안 함", 0), ("5분", 300), ("15분", 900), ("30분", 1800), ("1시간", 3600),
    ]

    static let idleFullscreenChoices: [(String, TimeInterval)] = [
        ("30초", 30), ("1분", 60), ("2분", 120), ("5분", 300), ("10분", 600),
    ]

    @objc private func rotationIntervalChanged() {
        UserDefaults.standard.set(Double(rotationPopup.selectedTag()), forKey: RotationController.intervalKey)
        // 켜는 순간부터 센다 — 예전 기준 시각이 남아 있으면 켜자마자 바뀐다(메뉴와 같게).
        RotationController.markChanged()
        onDisplayOptionsChanged()
    }

    @objc private func rotationShuffleChanged() {
        UserDefaults.standard.set(shuffleBox?.state == .on, forKey: RotationController.shuffleKey)
        onDisplayOptionsChanged()
    }

    @objc private func desktopIconsChanged() {
        DesktopIcons.setHidden(desktopIconsBox?.state == .on)
        desktopIconsBox?.state = DesktopIcons.isHidden ? .on : .off
        onDisplayOptionsChanged()
    }

    @objc private func idleFullscreenChanged() {
        idleFullscreenPopup.isEnabled = idleFullscreenBox?.state == .on
        UserDefaults.standard.set(
            idleFullscreenBox?.state == .on, forKey: IdleFullscreenController.enabledKey)
        UserDefaults.standard.set(
            Double(idleFullscreenPopup.selectedTag()), forKey: IdleFullscreenController.thresholdKey)
        onIdleFullscreenChanged()
    }

    @objc private func powerChanged() {
        var prefs = PowerPreferences()
        prefs.pauseWhenOccluded = occludedBox?.state == .on
        prefs.pauseInFullscreen = fullscreenBox?.state == .on
        prefs.batteryFPS = batteryPopup.selectedTag()
        prefs.idlePauseSeconds = TimeInterval(idlePopup.selectedTag())
        prefs.targetFPS = fpsPopup.selectedTag()
        PowerPreferencesStore.save(prefs)
        onPowerChanged()
    }

    @objc private func soundChanged() {
        UserDefaults.standard.set(soundBox?.state == .on, forKey: MenuBarController.soundKey)
        // 크기는 지금 걸린 배경화면에 저장한다(배경마다 따로). 없으면 전역 기본에.
        if let item = currentItem() {
            VolumePreferencesStore.setVolume(volumeSlider.doubleValue, for: item.id)
        } else {
            UserDefaults.standard.set(volumeSlider.doubleValue, forKey: SceneRenderer.volumeKey)
        }
        updateVolumeLabels(for: currentItem())
        onSoundChanged()
    }

    @objc private func audioChanged() {
        let enabled = audioBox?.state == .on
        if enabled, !MenuBarController.confirmAudioCapture() {
            audioBox?.state = .off
            return
        }
        UserDefaults.standard.set(enabled, forKey: AudioSpectrum.enabledKey)
        onAudioChanged(enabled)
    }

    @objc private func loginChanged() {
        let enable = loginBox?.state == .on
        if let reason = LoginItem.setEnabled(enable) {
            let alert = NSAlert()
            alert.messageText = enable ? "로그인 항목으로 등록하지 못했다" : "등록을 해제하지 못했다"
            alert.informativeText = LoginItem.isDeniedByUser
                ? "시스템 설정 > 일반 > 로그인 항목에서 Wallflow를 허용해 주세요." : reason
            alert.runModal()
        }
        loginBox?.state = LoginItem.isEnabled ? .on : .off
    }

}
