import AppKit
import WallflowKit

/// 창작마당 창 오른쪽 칸. 고른 항목(창작마당 미리보기 또는 설치된 배경화면)의
/// 자세한 정보를 보여 준다. 목록·필터와는 아무 관계가 없다 — 뭘 보여 줄지는
/// 전부 `showWorkshop`/`showInstalled`/`showEmpty` 호출자(창 컨트롤러)가 정한다.
@MainActor
final class WorkshopDetailPanel: NSView {
    /// 창작마당: 받기(안 받았으면)/적용(받았으면). 설치됨: 적용.
    var onPrimary: (() -> Void)?
    /// 설치됨 탭에서만: 지우기.
    var onRemove: (() -> Void)?

    private let editor: PropertyEditorView

    private let scrollView = NSScrollView()
    // 뒤집힌 좌표계 — 안 뒤집으면 스크롤 칸이 열릴 때 내용이 가운데로 몰려
    // 미리보기 위로 빈 띠가 남는다(사이드바와 같은 버릇, WorkshopSidebarView 참고).
    private let stack = FlippedStackView()

    private let previewContainer = NSView()
    private let previewImageView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let authorRow = NSStackView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let ratingRow = NSStackView()
    private let ratingCountLabel = NSTextField(labelWithString: "")
    private let subscribersRow = InfoRow()
    private let sizeRow = InfoRow()
    private let createdRow = InfoRow()
    private let updatedRow = InfoRow()
    private let tagsView = TagChipsView()
    private let descriptionView = AutoHeightTextView()
    private let progressBar = NSProgressIndicator()
    private let primaryButton = NSButton(title: "받기", target: nil, action: nil)
    private let steamButton = NSButton(title: "Steam에서 열기", target: nil, action: nil)
    private let removeButton = NSButton(title: "지우기", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    /// 스택 좌우·위아래 여백. `showInstalled`가 편집기를 나중에 끼워 넣을 때도
    /// 같은 값을 써야 한다.
    private let contentInset: CGFloat = 16

    /// "Steam에서 열기"가 열 주소. 항목을 보여 줄 때마다 채운다.
    private var steamWorkshopID: String?

    init(editor: PropertyEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        buildLayout()
        showEmpty()
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    // MARK: - 레이아웃

    private func buildLayout() {
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 8
        previewContainer.layer?.masksToBounds = true
        previewContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.animates = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            // 16:9 칸. 실제 배경화면 대부분이 이 비율이다.
            previewContainer.heightAnchor.constraint(
                equalTo: previewContainer.widthAnchor, multiplier: 9.0 / 16.0),
        ])

        titleLabel.font = .boldSystemFont(ofSize: 15)

        authorLabel.textColor = .secondaryLabelColor
        authorRow.orientation = .horizontal
        authorRow.spacing = 4
        authorRow.addArrangedSubview(NSTextField(labelWithString: "제작자"))
        (authorRow.arrangedSubviews.first as? NSTextField)?.textColor = .secondaryLabelColor
        authorRow.addArrangedSubview(authorLabel)

        ratingRow.orientation = .horizontal
        ratingRow.spacing = 2
        for _ in 0..<5 {
            let star = NSImageView()
            star.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            star.contentTintColor = .systemYellow
            ratingRow.addArrangedSubview(star)
        }
        ratingCountLabel.textColor = .secondaryLabelColor
        ratingCountLabel.font = .systemFont(ofSize: 11)
        ratingRow.addArrangedSubview(ratingCountLabel)

        descriptionView.isEditable = false
        descriptionView.isSelectable = true
        descriptionView.drawsBackground = false
        descriptionView.font = .systemFont(ofSize: 12)
        descriptionView.textColor = .labelColor

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = false

        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        steamButton.target = self
        steamButton.action = #selector(steamTapped)
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        let buttonRow = NSStackView(views: [primaryButton, steamButton, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // 아무것도 안 골랐을 때 — 스크롤 칸과 별개로 가운데 고정.
        emptyLabel.stringValue = "항목을 고르면 여기에 자세한 정보가 나온다"
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: contentInset, left: contentInset, bottom: contentInset, right: contentInset)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in [
            previewContainer, titleLabel, authorRow, ratingRow,
            subscribersRow, sizeRow, createdRow, updatedRow,
            tagsView, descriptionView, progressBar, buttonRow,
        ] {
            stack.addArrangedSubview(view)
            // 폭을 스택 폭 그대로 두면 edgeInsets의 좌우 여백이 지워진다 —
            // 여백만큼 빼야 실제로 안쪽에 여백이 남는다.
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -contentInset * 2).isActive = true
        }

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // 스크롤 칸 전체를 채우는 배경과 별개로 텍스트만 가운데 둔다.
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: contentInset),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -contentInset),
        ])

        editor.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - 표시

    /// 창작마당 항목. `page`는 아직 안 왔으면 nil로 넘긴다 — 평점·작성자 줄만 숨는다.
    func showWorkshop(
        item: WorkshopItem, preview: NSImage?, page: WorkshopDetailsPage?,
        installed: Bool, progress: Double?
    ) {
        scrollView.isHidden = false
        emptyLabel.isHidden = true
        steamWorkshopID = item.id

        previewImageView.image = preview
        titleLabel.stringValue = item.title
        setRow(authorRow, hidden: page?.author == nil)
        authorLabel.stringValue = page?.author ?? ""
        setRating(page?.rating, count: page?.ratingCount)

        subscribersRow.show(title: "구독자", value: "\(item.subscriptions.formatted())명")
        sizeRow.show(title: "크기", value: Self.byteFormatter.string(fromByteCount: Int64(item.sizeBytes)))
        setRow(createdRow, hidden: item.createdAt == nil)
        createdRow.show(title: "올린 날", value: item.createdAt.map(Self.dateFormatter.string) ?? "")
        setRow(updatedRow, hidden: item.updatedAt == nil)
        updatedRow.show(title: "고친 날", value: item.updatedAt.map(Self.dateFormatter.string) ?? "")

        tagsView.tags = item.tags
        descriptionView.string = WorkshopText.plain(fromBBCode: item.description)

        let isBusy = progress != nil
        progressBar.isHidden = !isBusy
        progressBar.doubleValue = progress ?? 0
        primaryButton.isEnabled = !isBusy
        primaryButton.title = installed ? "적용" : "받기"
        steamButton.isHidden = false
        removeButton.isHidden = true
        editor.removeFromSuperview()
    }

    /// 설치됨 탭. 속성 편집기는 이 배경화면 것으로 채워 버튼 줄 아래 붙인다.
    func showInstalled(item: WallpaperItem, preview: NSImage?) {
        scrollView.isHidden = false
        emptyLabel.isHidden = true
        steamWorkshopID = nil

        previewImageView.image = preview
        titleLabel.stringValue = item.title
        setRow(authorRow, hidden: true)
        setRating(nil, count: nil)
        subscribersRow.isHidden = true
        sizeRow.isHidden = true
        createdRow.isHidden = true
        updatedRow.isHidden = true
        tagsView.tags = []
        descriptionView.string = ""

        progressBar.isHidden = true
        primaryButton.isEnabled = true
        primaryButton.title = "적용"
        steamButton.isHidden = true
        removeButton.isHidden = false

        if editor.superview == nil {
            stack.addArrangedSubview(editor)
            editor.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -contentInset * 2).isActive = true
        }
        editor.show(item: item)
    }

    func showEmpty() {
        scrollView.isHidden = true
        emptyLabel.isHidden = false
        steamWorkshopID = nil
        editor.removeFromSuperview()
    }

    private func setRating(_ rating: Double?, count: Int?) {
        setRow(ratingRow, hidden: rating == nil)
        guard let rating else { return }
        let symbols = StarRating.symbols(for: rating)
        for (index, view) in ratingRow.arrangedSubviews.enumerated() where index < symbols.count {
            (view as? NSImageView)?.image = NSImage(
                systemSymbolName: symbols[index], accessibilityDescription: nil)
        }
        ratingCountLabel.stringValue = count.map { "(\($0.formatted()))" } ?? ""
    }

    private func setRow(_ view: NSView, hidden: Bool) {
        view.isHidden = hidden
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func removeTapped() { onRemove?() }
    @objc private func steamTapped() {
        guard let id = steamWorkshopID,
              let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        return formatter
    }()
}

/// "제목: 값" 한 줄. 값이 없으면 통째로 숨긴다.
private final class InfoRow: NSStackView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 4
        titleLabel.textColor = .secondaryLabelColor
        addArrangedSubview(titleLabel)
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    func show(title: String, value: String) {
        isHidden = false
        titleLabel.stringValue = title
        valueLabel.stringValue = value
    }
}

/// 태그 칩. 폭이 모자라면 다음 줄로 넘긴다 — `NSStackView`는 줄바꿈이 없어 직접 배치한다.
private final class TagChipsView: NSView {
    var tags: [String] = [] { didSet { rebuild() } }
    private var chipLabels: [NSTextField] = []

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    private var height: CGFloat = 0

    private func rebuild() {
        chipLabels.forEach { $0.removeFromSuperview() }
        chipLabels = tags.map { tag in
            let label = NSTextField(labelWithString: tag)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            label.layer?.cornerRadius = 8
            addSubview(label)
            return label
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8, spacing: CGFloat = 6, lineSpacing: CGFloat = 6
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for label in chipLabels {
            let size = label.intrinsicContentSize
            let width = size.width + padding * 2
            if x + width > bounds.width, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            label.frame = NSRect(x: x, y: y, width: width, height: size.height + 6)
            x += width + spacing
            lineHeight = max(lineHeight, size.height + 6)
        }
        let newHeight = chipLabels.isEmpty ? 0 : y + lineHeight
        if newHeight != height {
            height = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}

/// 스크롤 없이 내용 높이만큼 늘어나는 읽기 전용 텍스트 뷰.
private final class AutoHeightTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }
}
