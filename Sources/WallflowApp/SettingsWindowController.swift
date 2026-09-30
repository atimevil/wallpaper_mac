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
    private let onPropertiesChanged: () -> Void
    private let onPowerChanged: () -> Void
    private let onSoundChanged: () -> Void
    private let onAudioChanged: (Bool) -> Void

    private let tabs = NSTabView()
    private lazy var propertyEditor = PropertyEditorView(store: store, onChanged: onPropertiesChanged)

    init(store: UserPropertyStore,
         currentItem: @escaping () -> WallpaperItem?,
         onPropertiesChanged: @escaping () -> Void,
         onPowerChanged: @escaping () -> Void,
         onSoundChanged: @escaping () -> Void,
         onAudioChanged: @escaping (Bool) -> Void) {
        self.store = store
        self.currentItem = currentItem
        self.onPropertiesChanged = onPropertiesChanged
        self.onPowerChanged = onPowerChanged
        self.onSoundChanged = onSoundChanged
        self.onAudioChanged = onAudioChanged
        let window = UtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Wallflow 설정"
        window.center()
        super.init(window: window)
        window.contentView = makeContent()
        Self.current = self
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    /// 배경화면이 바뀌었을 때 속성 탭을 다시 채운다.
    func reloadProperties() {
        propertyEditor.show(item: currentItem())
    }

    /// 메뉴바에서 바꾼 값을 다시 읽는다. 창이 열린 채로 메뉴에서 바꾸면 여기 남은
    /// 옛 값이 다음 `powerChanged()`에서 메뉴의 선택을 덮어쓴다.
    func reloadPower() {
        let prefs = PowerPreferencesStore.load()
        occludedBox?.state = prefs.pauseWhenOccluded ? .on : .off
        fullscreenBox?.state = prefs.pauseInFullscreen ? .on : .off
        idlePopup.selectItem(withTag: Int(prefs.idlePauseSeconds))
        fpsPopup.selectItem(withTag: prefs.targetFPS)
        batteryPopup.selectItem(withTag: prefs.batteryFPS)
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

    private func makeGeneralTab() -> NSView {
        let prefs = PowerPreferencesStore.load()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(label)
        }
        func check(_ title: String, on: Bool, _ action: Selector) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: self, action: action)
            box.state = on ? .on : .off
            stack.addArrangedSubview(box)
            return box
        }

        heading("재생")
        occludedBox = check("다른 창에 완전히 가려지면 멈춤", on: prefs.pauseWhenOccluded,
                            #selector(powerChanged))
        fullscreenBox = check("전체화면 앱이 뜨면 멈춤", on: prefs.pauseInFullscreen,
                              #selector(powerChanged))

        let idleRow = NSStackView()
        idleRow.orientation = .horizontal
        idleRow.addArrangedSubview(NSTextField(labelWithString: "입력이 없으면 멈춤:"))
        for (label, seconds) in Self.idleChoices {
            idlePopup.addItem(withTitle: label)
            idlePopup.lastItem?.tag = Int(seconds)
        }
        idlePopup.selectItem(withTag: Int(prefs.idlePauseSeconds))
        if idlePopup.indexOfSelectedItem < 0 { idlePopup.selectItem(at: 0) }
        idlePopup.target = self
        idlePopup.action = #selector(powerChanged)
        idleRow.addArrangedSubview(idlePopup)
        stack.addArrangedSubview(idleRow)

        let fpsRow = NSStackView()
        fpsRow.orientation = .horizontal
        fpsRow.addArrangedSubview(NSTextField(labelWithString: "프레임(전원 연결):"))
        for fps in PowerPreferences.allowedFPS {
            fpsPopup.addItem(withTitle: "\(fps)")
            fpsPopup.lastItem?.tag = fps
        }
        fpsPopup.selectItem(withTag: prefs.targetFPS)
        fpsPopup.target = self
        fpsPopup.action = #selector(powerChanged)
        fpsRow.addArrangedSubview(fpsPopup)
        stack.addArrangedSubview(fpsRow)

        let batteryRow = NSStackView()
        batteryRow.orientation = .horizontal
        batteryRow.addArrangedSubview(NSTextField(labelWithString: "배터리·저전력일 때:"))
        for (label, fps) in PowerPreferencesStore.batteryChoices {
            batteryPopup.addItem(withTitle: label)
            batteryPopup.lastItem?.tag = fps
        }
        batteryPopup.selectItem(withTag: prefs.batteryFPS)
        batteryPopup.target = self
        batteryPopup.action = #selector(powerChanged)
        batteryRow.addArrangedSubview(batteryPopup)
        stack.addArrangedSubview(batteryRow)

        heading("소리")
        soundBox = check("씬 소리", on: UserDefaults.standard.bool(forKey: MenuBarController.soundKey),
                         #selector(soundChanged))
        let volumeRow = NSStackView()
        volumeRow.orientation = .horizontal
        volumeRow.addArrangedSubview(NSTextField(labelWithString: "크기:"))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = SceneRenderer.soundVolume
        volumeSlider.target = self
        volumeSlider.action = #selector(soundChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        volumeRow.addArrangedSubview(volumeSlider)
        stack.addArrangedSubview(volumeRow)
        audioBox = check("소리에 반응하기 (시스템 소리를 듣는다)", on: AudioSpectrum.isEnabled,
                         #selector(audioChanged))

        heading("시작")
        loginBox = check("로그인할 때 시작", on: LoginItem.isEnabled, #selector(loginChanged))

        return Self.scrolling(stack)
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
    private let idlePopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let batteryPopup = NSPopUpButton()
    private let volumeSlider = NSSlider()
    static let idleChoices: [(String, TimeInterval)] = [
        ("안 함", 0), ("5분", 300), ("15분", 900), ("30분", 1800), ("1시간", 3600),
    ]

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
        UserDefaults.standard.set(volumeSlider.doubleValue, forKey: SceneRenderer.volumeKey)
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
