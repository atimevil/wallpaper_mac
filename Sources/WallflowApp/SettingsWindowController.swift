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
    private let propertiesStack = NSStackView()
    private let propertiesTitle = NSTextField(labelWithString: "")
    private var properties: [UserProperty] = []
    private var values: [String: UserPropertyValue] = [:]
    private var itemID: String?
    /// 컨트롤 ↔ 속성 이름. 조건이 바뀌면 보이고 숨기는 데 쓴다.
    private var rows: [(name: String, view: NSView)] = []

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
        let window = NSWindow(
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
        rows.removeAll()
        propertiesStack.arrangedSubviews.forEach {
            propertiesStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        guard let item = currentItem() else {
            propertiesTitle.stringValue = "걸린 배경화면이 없다"
            properties = []
            return
        }
        itemID = item.id
        let data = (try? Data(contentsOf: item.directory.appendingPathComponent("project.json")))
            ?? Data()
        properties = UserProperty.load(projectJSON: data)
        let overrides = store.overrides(for: item.id)
        // 프리셋 항목이면 프리셋의 값이 기본값 노릇을 한다.
        values = Dictionary(uniqueKeysWithValues: properties.map {
            ($0.name, overrides[$0.name] ?? item.presetValues[$0.name] ?? $0.defaultValue)
        })
        propertiesTitle.stringValue = properties.isEmpty
            ? "\(item.title) — 이 배경화면은 조절할 것이 없다"
            : item.title
        for property in properties {
            let row = makeRow(for: property)
            rows.append((property.name, row))
            propertiesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: propertiesStack.widthAnchor).isActive = true
        }
        if !properties.isEmpty {
            let reset = NSButton(title: "기본값으로", target: self, action: #selector(resetAll))
            propertiesStack.addArrangedSubview(reset)
        }
        applyConditions()
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
        batteryBox = check("배터리·저전력이면 프레임을 낮춤", on: prefs.reduceOnBattery,
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
        fpsRow.addArrangedSubview(NSTextField(labelWithString: "프레임:"))
        for fps in PowerPreferences.allowedFPS {
            fpsPopup.addItem(withTitle: "\(fps)")
            fpsPopup.lastItem?.tag = fps
        }
        fpsPopup.selectItem(withTag: prefs.targetFPS)
        fpsPopup.target = self
        fpsPopup.action = #selector(powerChanged)
        fpsRow.addArrangedSubview(fpsPopup)
        stack.addArrangedSubview(fpsRow)

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
        propertiesStack.orientation = .vertical
        propertiesStack.alignment = .leading
        propertiesStack.spacing = 10
        propertiesStack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        propertiesTitle.font = .boldSystemFont(ofSize: 13)

        let outer = NSStackView(views: [propertiesTitle, propertiesStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        propertiesTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = Self.scrolling(outer)
        propertiesStack.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        propertiesTitle.leadingAnchor.constraint(
            equalTo: outer.leadingAnchor, constant: 20).isActive = true
        return scroll
    }

    /// 속성 하나의 줄. 종류마다 알맞은 컨트롤을 단다.
    private func makeRow(for property: UserProperty) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let value = values[property.name] ?? property.defaultValue
        switch property.kind {
        case .toggle:
            let box = NSButton(checkboxWithTitle: property.label, target: self,
                               action: #selector(controlChanged(_:)))
            if case .toggle(let on) = value { box.state = on ? .on : .off }
            box.identifier = NSUserInterfaceItemIdentifier(property.name)
            row.addArrangedSubview(box)
        case .slider(let lo, let hi, let step):
            row.addArrangedSubview(label(property.label))
            let slider = NSSlider(value: 0, minValue: lo, maxValue: hi, target: self,
                                  action: #selector(controlChanged(_:)))
            if case .number(let d) = value { slider.doubleValue = d }
            if step > 0 {
                slider.allowsTickMarkValuesOnly = false
                slider.numberOfTickMarks = min(50, Int((hi - lo) / step) + 1)
            }
            slider.identifier = NSUserInterfaceItemIdentifier(property.name)
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            row.addArrangedSubview(slider)
            let readout = NSTextField(labelWithString: Self.format(slider.doubleValue))
            readout.identifier = NSUserInterfaceItemIdentifier(property.name + "::readout")
            readout.textColor = .secondaryLabelColor
            row.addArrangedSubview(readout)
        case .color:
            row.addArrangedSubview(label(property.label))
            let well = NSColorWell()
            if case .color(let c) = value {
                well.color = NSColor(red: c.x, green: c.y, blue: c.z, alpha: 1)
            }
            well.target = self
            well.action = #selector(controlChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(property.name)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(well)
        case .combo(let options):
            row.addArrangedSubview(label(property.label))
            let popup = NSPopUpButton()
            for option in options { popup.addItem(withTitle: option.label) }
            if case .text(let current) = value,
               let index = options.firstIndex(where: { $0.value == current }) {
                popup.selectItem(at: index)
            }
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(property.name)
            row.addArrangedSubview(popup)
        case .textInput:
            row.addArrangedSubview(label(property.label))
            let field = NSTextField()
            if case .text(let text) = value { field.stringValue = text }
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.identifier = NSUserInterfaceItemIdentifier(property.name)
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
            row.addArrangedSubview(field)
        case .text:
            let note = NSTextField(wrappingLabelWithString: property.label)
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 11)
            row.addArrangedSubview(note)
        case .texture:
            // 파일 고르기는 아직 없다. 프리셋이 준 파일이면 그 이름을 보여 준다.
            row.addArrangedSubview(label(property.label))
            var name = "(기본 그림)"
            if case .text(let path) = value, !path.isEmpty {
                name = (path as NSString).lastPathComponent
            }
            let note = NSTextField(labelWithString: name)
            note.textColor = .secondaryLabelColor
            row.addArrangedSubview(note)
        }
        return row
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return field
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// 조건에 따라 줄을 보이고 숨긴다. 값이 하나 바뀌면 다른 줄의 조건이 바뀐다.
    private func applyConditions() {
        for property in properties {
            guard let row = rows.first(where: { $0.name == property.name }) else { continue }
            row.view.isHidden = !UserProperty.isVisible(property, values: values)
        }
    }

    // MARK: - 반응

    private var occludedBox: NSButton?
    private var fullscreenBox: NSButton?
    private var batteryBox: NSButton?
    private var soundBox: NSButton?
    private var audioBox: NSButton?
    private var loginBox: NSButton?
    private let idlePopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let volumeSlider = NSSlider()
    static let idleChoices: [(String, TimeInterval)] = [
        ("안 함", 0), ("5분", 300), ("15분", 900), ("30분", 1800), ("1시간", 3600),
    ]

    @objc private func powerChanged() {
        var prefs = PowerPreferences()
        prefs.pauseWhenOccluded = occludedBox?.state == .on
        prefs.pauseInFullscreen = fullscreenBox?.state == .on
        prefs.reduceOnBattery = batteryBox?.state == .on
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

    @objc private func controlChanged(_ sender: NSControl) {
        guard let name = sender.identifier?.rawValue,
              let property = properties.first(where: { $0.name == name }) else { return }
        switch (property.kind, sender) {
        case (.toggle, let box as NSButton):
            values[name] = .toggle(box.state == .on)
        case (.slider(let lo, let hi, let step), let slider as NSSlider):
            var v = slider.doubleValue
            if step > 0 { v = lo + ((v - lo) / step).rounded() * step }
            v = min(max(v, lo), hi)
            values[name] = .number(v)
            if let row = rows.first(where: { $0.name == name })?.view as? NSStackView,
               let readout = row.arrangedSubviews.first(where: {
                   $0.identifier?.rawValue == name + "::readout" }) as? NSTextField {
                readout.stringValue = Self.format(v)
            }
        case (.color, let well as NSColorWell):
            let c = well.color.usingColorSpace(.sRGB) ?? well.color
            values[name] = .color(Vec3(x: Double(c.redComponent), y: Double(c.greenComponent),
                                       z: Double(c.blueComponent)))
        case (.combo(let options), let popup as NSPopUpButton):
            let index = popup.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            values[name] = .text(options[index].value)
        case (.textInput, let field as NSTextField):
            values[name] = .text(field.stringValue)
        default:
            return
        }
        persistAndReload()
    }

    @objc private func resetAll() {
        values = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.defaultValue) })
        persistAndReload()
        reloadProperties()
    }

    /// 기본값과 다른 것만 저장한다. 전부 저장하면 제작자가 기본값을 바꿔도
    /// 옛 값에 묶인다.
    private func persistAndReload() {
        guard let itemID else { return }
        var overrides: [String: UserPropertyValue] = [:]
        for property in properties {
            if let value = values[property.name], value != property.defaultValue {
                overrides[property.name] = value
            }
        }
        do {
            try store.save(overrides, for: itemID)
        } catch {
            let alert = NSAlert()
            alert.messageText = "설정을 저장하지 못했다"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        applyConditions()
        onPropertiesChanged()
    }
}
