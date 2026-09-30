import AppKit

/// 칸을 왼쪽부터 빈틈없이 채우는 격자 배치.
///
/// `NSCollectionViewFlowLayout`은 한 줄에 칸이 다 안 들어차면 남는 자리를
/// 칸 "사이 간격"으로 늘려버린다 — 칸 두 개가 양 끝에 붙고 가운데가 뻥 뚫려
/// 보인다. 여기선 간격을 고정하고, 남는 자리는 칸 너비를 키워 흡수한다
/// (Wallpaper Engine 격자처럼). 직접 프레임을 계산하므로 흐름 배치의 그
/// 버릇에서 아예 벗어난다.
final class WorkshopGridLayout: NSCollectionViewLayout {
    /// 사용자가 슬라이더로 고른 "바랐으면 하는" 칸 너비. 실제 칸은 이 값
    /// 근처에서 남는 자리를 다 채우게 조금 늘어난다.
    var targetCellWidth: CGFloat = 220 {
        didSet { invalidateLayout() }
    }
    var spacing: CGFloat = 12
    var sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    /// 칸 높이 = 너비(정사각 미리보기) + 이 만큼(제목 한 줄).
    var titleRowHeight: CGFloat = 20

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    /// 보이는 폭. 컬렉션 뷰 자기 폭을 쓰면 문서 폭이 내용 크기를 따라가므로
    /// 상세 칸이 넓어져 보이는 자리가 줄어도 예전 폭에 머물러 오른쪽 칸이 잘린다.
    private var visibleWidth: CGFloat {
        collectionView?.enclosingScrollView?.contentView.bounds.width
            ?? collectionView?.bounds.width ?? 0
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: visibleWidth, height: contentHeight)
    }

    override func prepare() {
        attributes = []
        guard let collectionView else { contentHeight = 0; return }
        let count = collectionView.numberOfItems(inSection: 0)
        let available = visibleWidth - sectionInset.left - sectionInset.right
        guard count > 0, available > 0 else { contentHeight = 0; return }

        // 반올림 — 내림이면 2.9칸 자리에 2칸이 들어가 칸이 바란 크기보다 50%나
        // 커진다(기본 220이 330으로). 반올림이면 바란 크기 ±절반 칸 안에 든다.
        let fit = (available + spacing) / (targetCellWidth + spacing)
        let columns = Swift.max(1, Int(fit.rounded()))
        let width = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let height = width + titleRowHeight

        var x = sectionInset.left
        var y = sectionInset.top
        var column = 0
        for index in 0..<count {
            let attr = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            attr.frame = NSRect(x: x, y: y, width: width, height: height)
            attributes.append(attr)
            column += 1
            if column == columns {
                column = 0
                x = sectionInset.left
                y += height + spacing
            } else {
                x += width + spacing
            }
        }
        contentHeight = y + (column == 0 ? 0 : height) + sectionInset.bottom
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes.first { $0.indexPath == indexPath }
    }

    /// 너비가 바뀌면(창 크기·상세 칸 폭) 칸 수를 다시 셈해야 한다.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}
