import AppKit
import WallflowKit

/// 배경화면 속성 편집기. 설정 창 속성 탭과 창작마당 옆 패널이 함께 쓴다.
/// 저장·조건부 표시·초기화·슬라이더 수치 표시·오류 알림은 모두 여기 있다.
@MainActor
final class PropertyEditorView: NSView {
    private let store: UserPropertyStore
    /// 편집 중인 배경 id를 넘긴다 — 그 배경이 걸린 화면만 다시 열게(화면별 배경).
    private let onChanged: (String) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var properties: [UserProperty] = []
    private var values: [String: UserPropertyValue] = [:]
    private var itemID: String?
    private var currentItem: WallpaperItem?
    /// 컨트롤 ↔ 속성 이름. 조건이 바뀌면 보이고 숨기는 데 쓴다.
    private var rows: [(name: String, view: NSView)] = []

    /// 창작마당 상세 패널은 자기 제목을 이미 보여 주므로 여기서 또 안 보여 준다
    /// — 설정 창 속성 탭은 계속 보여 준다(기본값).
    init(store: UserPropertyStore, onChanged: @escaping (String) -> Void, showsTitle: Bool = true) {
        self.store = store
        self.onChanged = onChanged
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.isHidden = !showsTitle
        // 제목을 안 보이는 쪽은 상세 패널에 끼워 넣는 경우다 — 패널이 이미 좌우
        // 여백을 두므로 또 들이면 패널의 다른 줄보다 20만큼 안으로 밀린다.
        if !showsTitle {
            stack.edgeInsets.left = 0
            stack.edgeInsets.right = 0
        }

        let outer = NSStackView(views: [titleLabel, stack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        // 상세 패널은 위에 "속성" 머리를 따로 달므로 위 여백까지 겹치면 크게 벌어진다.
        if !showsTitle {
            outer.edgeInsets.top = 0
            stack.edgeInsets.top = 0
        }
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        stack.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        titleLabel.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 20)
            .isActive = true
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    /// 조절할 속성이 없는지. 상세 패널이 "속성" 머리를 숨길 때 본다.
    var isEmpty: Bool { properties.isEmpty }

    /// 이 배경화면의 속성을 보여 준다. nil이면 "속성이 없다" 안내.
    func show(item: WallpaperItem?) {
        rows.removeAll()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        currentItem = item
        guard let item else {
            titleLabel.stringValue = "걸린 배경화면이 없다"
            properties = []
            itemID = nil
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
        titleLabel.stringValue = properties.isEmpty
            ? "\(item.title) — 이 배경화면은 조절할 것이 없다"
            : item.title
        for property in properties {
            let row = makeRow(for: property)
            rows.append((property.name, row))
            stack.addArrangedSubview(row)
            // 좌우 여백을 빼야 줄이 "기본값으로" 버튼·제목과 같은 선에서 시작한다.
            row.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        if !properties.isEmpty {
            let reset = NSButton(title: "기본값으로", target: self, action: #selector(resetAll))
            stack.addArrangedSubview(reset)
        }
        applyConditions()
    }

    /// 폭은 바라는 값일 뿐 최소만 지킨다. 고정 폭이면 좁은 상세 패널(340)에서
    /// 라벨+컨트롤이 넘쳐 패널을 420까지 밀고 격자가 출렁인다.
    private static func preferWidth(_ view: NSView, _ width: CGFloat, atLeast minimum: CGFloat) {
        let preferred = view.widthAnchor.constraint(equalToConstant: width)
        preferred.priority = .defaultLow
        preferred.isActive = true
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum).isActive = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            Self.preferWidth(slider, 200, atLeast: 80)
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
            Self.preferWidth(field, 240, atLeast: 100)
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
        show(item: currentItem)
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
        onChanged(itemID)
    }
}
