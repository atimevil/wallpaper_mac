import AppKit
import WallflowKit

/// 창작마당 왼쪽 필터 사이드바. `WorkshopFilterSection.allCases` 순서로
/// 제목+체크박스 목록을 스크롤 목록으로 보여 주고, 맨 아래 "받은 것 숨기기"·
/// "초기화"를 고정으로 둔다.
///
/// 상태는 여기서 들고 있지 않는다 — `WorkshopFilterState`는 컨트롤러가
/// 관리하고, 이 뷰는 바뀔 때마다 통째로 새 상태를 받아 되그린다. 판정은
/// 전부 Kit의 `WorkshopFilterState`가 한다.
@MainActor
final class WorkshopSidebarView: NSView {
    private let onChanged: (WorkshopFilterState) -> Void
    private var state: WorkshopFilterState
    /// 섹션·태그 값으로 되짚어 갱신할 수 있게 체크박스를 기억해 둔다.
    private var checkboxes: [(section: WorkshopFilterSection, tag: String, button: NSButton)] = []
    private let hideInstalledCheckbox =
        NSButton(checkboxWithTitle: "받은 것 숨기기", target: nil, action: nil)
    private let resetButton = NSButton(title: "초기화", target: nil, action: nil)

    private static let sectionTitles: [WorkshopFilterSection: String] = [
        .kind: "종류", .rating: "등급", .resolution: "해상도",
        .genre: "장르", .flag: "특성",
    ]

    init(initial: WorkshopFilterState, onChanged: @escaping (WorkshopFilterState) -> Void) {
        self.state = initial
        self.onChanged = onChanged
        super.init(frame: .zero)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        for section in WorkshopFilterSection.allCases {
            let title = NSTextField(labelWithString: Self.sectionTitles[section] ?? "")
            title.font = .boldSystemFont(ofSize: 12)
            let sectionStack = NSStackView(views: [title])
            sectionStack.orientation = .vertical
            sectionStack.alignment = .leading
            sectionStack.spacing = 4
            for choice in section.choices {
                let checkbox = NSButton(
                    checkboxWithTitle: choice.label, target: self, action: #selector(checkboxToggled))
                checkbox.tag = checkboxes.count
                checkboxes.append((section, choice.tag, checkbox))
                sectionStack.addArrangedSubview(checkbox)
            }
            list.addArrangedSubview(sectionStack)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        hideInstalledCheckbox.target = self
        hideInstalledCheckbox.action = #selector(hideInstalledToggled)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        let bottom = NSStackView(views: [hideInstalledCheckbox, resetButton])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [scroll, bottom])
        outer.orientation = .vertical
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    /// 바깥에서 상태를 되돌릴 때(예: 다른 탭으로 옮기며 초기화) 쓴다. 알림은
    /// 다시 보내지 않는다 — 그 상태를 만든 쪽이 이미 알고 있다.
    func setState(_ newState: WorkshopFilterState) {
        state = newState
        refreshControls()
    }

    private func refreshControls() {
        for (section, tag, button) in checkboxes {
            let on = (state.selected[section] ?? []).contains(tag)
            button.state = on ? .on : .off
        }
        hideInstalledCheckbox.state = state.hideInstalled ? .on : .off
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard sender.tag < checkboxes.count else { return }
        let entry = checkboxes[sender.tag]
        state.toggle(entry.tag, in: entry.section)
        onChanged(state)
    }

    @objc private func hideInstalledToggled() {
        state.hideInstalled = hideInstalledCheckbox.state == .on
        onChanged(state)
    }

    @objc private func resetTapped() {
        state.reset()
        refreshControls()
        onChanged(state)
    }
}
