import AppKit
import WallflowKit

/// 격자에 그리는 한 칸. 라이브러리 항목과 창작마당 항목을 같은 모양으로 보여 준다.
struct GridEntry {
    let id: String
    let title: String
    let installed: Bool
}

/// 칸을 꽉 채우는 그림. 비율을 지키고 넘치는 쪽을 자른다.
///
/// 레이어에 직접 그리므로 `NSImageView`가 아니다. 그쪽에는 "채우기" 축척이
/// 없어서, 16:9 배경화면이 정사각형 칸에서 위아래로 회색 띠를 남긴다.
final class PreviewView: NSView {
    var image: NSImage? {
        didSet { updateContents() }
    }

    override func layout() {
        super.layout()
        // 화면 배율이 바뀌면 다시 물어봐야 선명하다.
        updateContents()
    }

    private func updateContents() {
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        guard let image else {
            layer?.contents = nil
            return
        }
        // 칸 비율에 맞춰 CGImage를 꺼낸다. NSImage를 그대로 넣으면 표현이
        // 여럿일 때(아이콘 등) 어느 것이 쓰일지 정해지지 않는다.
        var rect = CGRect(origin: .zero, size: bounds.size)
        layer?.contents = image.cgImage(
            forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// 격자 한 칸 — 정사각 미리보기 + 제목 한 줄.
///
/// 실물 창작마당 격자 그대로: 그림은 정사각, 제목은 그 아래 한 줄이다.
/// 받은 항목은 오른쪽 위 체크 배지, 받는 중이면 아래 진행 막대가 뜬다.
/// 마우스가 올라오면(호버) 같은 자리에 GIF를 애니메이션으로 튼다 — 한 번에
/// 이 칸 하나만 움직인다. 재사용될 때(스크롤) 반드시 꺼 둔다.
final class WorkshopGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkshopGridItem")

    /// 정지 미리보기. **칸을 꽉 채운다.**
    private let preview = PreviewView()
    /// 호버 중에만 보이는 애니메이션 그림. GIF가 아니면 그냥 정지 상태로 보인다.
    ///
    /// ponytail: 원본 비율을 살리는 채우기 대신 늘려서 채운다(크롭 없음) —
    /// 호버 몇 초 동안의 눈요기라 `preview`와 픽셀 단위로 안 맞아도 된다.
    /// 크롭까지 맞추려면 CALayer로 프레임을 직접 구워야 한다.
    private let animatedView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    private let progressBar = NSProgressIndicator()
    private let box = NSView()
    private var trackingArea: NSTrackingArea?
    private var cachedImage: NSImage?

    override func loadView() {
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor.clear.cgColor

        preview.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false

        animatedView.imageScaling = .scaleAxesIndependently
        animatedView.isHidden = true
        animatedView.translatesAutoresizingMaskIntoConstraints = false

        let imageBox = NSView()
        imageBox.wantsLayer = true
        imageBox.layer?.cornerRadius = 8
        imageBox.layer?.masksToBounds = true
        imageBox.layer?.borderWidth = 2
        imageBox.layer?.borderColor = NSColor.clear.cgColor
        imageBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageBox.translatesAutoresizingMaskIntoConstraints = false
        imageBox.addSubview(preview)
        imageBox.addSubview(animatedView)

        badge.image = NSImage(
            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "받음")
        badge.contentTintColor = .controlAccentColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        imageBox.addSubview(badge)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        imageBox.addSubview(progressBar)

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(imageBox)
        box.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            imageBox.topAnchor.constraint(equalTo: box.topAnchor),
            imageBox.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            imageBox.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            // 정사각. 칸 너비가 곧 그림 높이다.
            imageBox.heightAnchor.constraint(equalTo: imageBox.widthAnchor),

            preview.topAnchor.constraint(equalTo: imageBox.topAnchor),
            preview.bottomAnchor.constraint(equalTo: imageBox.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: imageBox.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor),
            animatedView.topAnchor.constraint(equalTo: imageBox.topAnchor),
            animatedView.bottomAnchor.constraint(equalTo: imageBox.bottomAnchor),
            animatedView.leadingAnchor.constraint(equalTo: imageBox.leadingAnchor),
            animatedView.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor),

            badge.topAnchor.constraint(equalTo: imageBox.topAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),

            progressBar.leadingAnchor.constraint(equalTo: imageBox.leadingAnchor, constant: 6),
            progressBar.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor, constant: -6),
            progressBar.bottomAnchor.constraint(equalTo: imageBox.bottomAnchor, constant: -6),

            nameLabel.topAnchor.constraint(equalTo: imageBox.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor),
        ])
        view = box
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTrackingArea()
    }

    /// - Parameter downloadProgress: 0...1이면 받는 중 — 진행 막대를 보인다.
    ///   nil이면 받는 중이 아니다(설치 배지는 그때만 뜬다).
    func configure(entry: GridEntry, image: NSImage?, downloadProgress: Double?) {
        cachedImage = image
        preview.image = image
        nameLabel.stringValue = entry.title
        badge.isHidden = downloadProgress != nil || !entry.installed
        if let progress = downloadProgress {
            progressBar.isHidden = false
            progressBar.doubleValue = progress
        } else {
            progressBar.isHidden = true
        }
        // 재사용된 칸이 이전 항목의 호버 애니메이션을 그대로 물려받지 않게 한다.
        stopHoverAnimation()
    }

    /// 다운로드 진행률 줄마다 온다. `configure`와 달리 그림·제목·호버 상태는
    /// 건드리지 않는다 — 매번 다시 그리면 깜빡이고 호버 애니메이션이 끊긴다.
    func updateProgress(_ fraction: Double) {
        badge.isHidden = true
        progressBar.isHidden = false
        progressBar.doubleValue = fraction
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopHoverAnimation()
    }

    private func updateTrackingArea() {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: view.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
    }

    /// 지금 애니메이션 중인 칸. 빠르게 지나가거나 스크롤 중에는 `mouseExited`가
    /// 못 오는 경우가 있어, 트래킹만으로는 "한 번에 하나"를 못 지킨다 — 새로
    /// 들어온 칸이 이전 칸을 직접 꺼 준다.
    private static weak var hovering: WorkshopGridItem?

    override func mouseEntered(with event: NSEvent) {
        guard let cachedImage else { return }
        Self.hovering?.stopHoverAnimation()
        Self.hovering = self
        animatedView.image = cachedImage
        animatedView.isHidden = false
        animatedView.animates = true
    }

    override func mouseExited(with event: NSEvent) {
        stopHoverAnimation()
    }

    private func stopHoverAnimation() {
        if Self.hovering === self { Self.hovering = nil }
        animatedView.animates = false
        animatedView.isHidden = true
        animatedView.image = nil
    }

    override var isSelected: Bool {
        didSet {
            box.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }
}
