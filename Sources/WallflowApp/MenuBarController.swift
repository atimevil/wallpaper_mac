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
    private let onToggleAudio: (Bool) -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var items: [WallpaperItem] = []

    init(
        onSelect: @escaping (WallpaperItem) -> Void,
        onRefresh: @escaping () -> Void,
        onBrowseWorkshop: @escaping () -> Void,
        onToggleSound: @escaping (Bool) -> Void,
        onToggleAudio: @escaping (Bool) -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggleSound = onToggleSound
        self.onToggleAudio = onToggleAudio
        self.onOpenSettings = onOpenSettings
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

    /// 설정 창에서 값이 바뀌면 메뉴의 체크 표시도 따라가야 한다.
    func refreshStates() { rebuildMenu() }

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
                // 열 수 없는 것은 그렇다고 적는다. 목록에서 빼면 사용자는 자기가
                // 받은 것이 왜 안 보이는지 알 수 없고, 아무 표시 없이 두면
                // 골랐을 때 왜 안 바뀌는지 알 수 없다.
                let label = item.unsupportedReason == nil
                    ? "\(item.title)  (\(item.type.rawValue))"
                    : "\(item.title)  (열 수 없음)"
                let menuItem = NSMenuItem(
                    title: label,
                    action: #selector(select(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                // 씬은 M2부터 이미지 레이어를 그린다. 못 그리면 preview로 폴백한다.
                menuItem.isEnabled = (item.type != .unsupported)
                // 왜 못 여는지는 마우스를 올리면 보인다. 메뉴 이름에 다 적으면
                // 목록이 읽기 어려워진다.
                menuItem.toolTip = item.unsupportedReason
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

        // 씬마다 소리 크기가 제각각이라 켜고 끄는 것만으로는 부족하다.
        // 씬이 정한 볼륨에 곱해지므로, 씬 안의 균형은 그대로 남는다.
        let volumeItem = NSMenuItem(title: "소리 크기", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        let current = SceneRenderer.soundVolume
        for percent in [0, 25, 50, 75, 100] {
            let entry = NSMenuItem(
                title: "\(percent)%", action: #selector(setVolume), keyEquivalent: "")
            entry.target = self
            entry.tag = percent
            // 저장된 값이 목록에 없는 값일 수도 있다. 가장 가까운 것에 표시한다 —
            // 아무 데도 표시가 없으면 지금 크기를 알 수 없다.
            entry.state = abs(current * 100 - Double(percent)) < 12.5 ? .on : .off
            volumeMenu.addItem(entry)
        }
        volumeItem.submenu = volumeMenu
        // 소리가 꺼져 있어도 크기는 정할 수 있게 둔다. 켜기 전에 미리 줄여 두는 것이
        // 자연스럽고, 막아 두면 왜 안 눌리는지 알 수 없다.
        menu.addItem(volumeItem)

        // 오디오 반응. 켜면 시스템 소리를 듣고 macOS가 화면 녹화 권한을 묻는다 —
        // 시스템 오디오 캡처가 그 권한 아래 있다. 기본은 꺼짐이다.
        let audio = NSMenuItem(
            title: "소리에 반응하기", action: #selector(toggleAudio), keyEquivalent: "")
        audio.target = self
        audio.state = AudioSpectrum.isEnabled ? .on : .off
        menu.addItem(audio)

        let settings = NSMenuItem(
            title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    @objc private func openSettings() { onOpenSettings() }

    @objc private func setVolume(_ sender: NSMenuItem) {
        UserDefaults.standard.set(
            Double(sender.tag) / 100, forKey: SceneRenderer.volumeKey)
        rebuildMenu()
        // 소리 설정을 다시 적용하는 경로가 이것뿐이다. 켬/끔과 같은 길을 쓴다.
        onToggleSound(UserDefaults.standard.bool(forKey: Self.soundKey))
    }

    @objc private func browseWorkshop() { onBrowseWorkshop() }

    @objc private func select(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func refresh() { onRefresh() }
    @objc private func quit() { onQuit() }
}
