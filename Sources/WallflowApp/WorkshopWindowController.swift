import AppKit
import WallflowKit

/// 창을 무엇으로 채우는지.
enum WorkshopTab: Int, CaseIterable {
    /// 받아 둔 배경화면. 먼저 보이는 것이 맞다 — 매일 쓰는 것은 이쪽이다.
    case installed
    /// 창작마당 둘러보기·검색(하나로 합쳤다).
    case browse

    var label: String {
        switch self {
        case .installed: return "설치됨"
        case .browse: return "창작마당"
        }
    }
}

/// 배경화면을 고르고, 창작마당에서 받아 라이브러리에 넣는 창.
///
/// 세 칸이다: 왼쪽 체크박스 필터 사이드바, 가운데 호버 GIF·무한 스크롤 격자,
/// 오른쪽 상세 패널.
///
/// 목록은 스팀에서 읽고, 다운로드는 steamcmd가 한다. 자격 증명은 이 앱이 만지지
/// 않는다 — steamcmd가 비밀번호와 Steam Guard를 대화식으로만 받으므로, 사용자가
/// 터미널에서 한 번 로그인해 캐시를 만들어야 한다. 그 상태를 안내로 알린다.
@MainActor
final class WorkshopWindowController: NSWindowController {
    /// steamcmd 로그인에 쓸 계정 이름. 비밀번호는 저장하지 않는다.
    private static let accountKey = "wallflow.steamAccount"
    private static let cellSizeKey = "wallflow.workshop.cellSize"
    private static let minCellSize: CGFloat = 160
    private static let maxCellSize: CGFloat = 320

    private let client = WorkshopClient()
    private let installer: WorkshopInstaller
    private let onLibraryChanged: () -> Void
    /// 라이브러리 목록을 읽어 오는 곳.
    private let libraryItems: () -> [WallpaperItem]
    /// 라이브러리에서 고른 것을 배경화면으로 건다.
    private let onApply: (WallpaperItem) -> Void
    /// 지금 켜진 배경화면 id. 격자·상세 패널이 "사용 중"을 가린다.
    private let currentItemID: () -> String?

    private let tabControl = NSSegmentedControl(
        labels: WorkshopTab.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let accountLabel = NSTextField(labelWithString: "계정:")
    /// 사이드바 접기. 분할 뷰 경계를 끌어 접게 하려면 사이드바 폭 제약 우선순위를
    /// 끌기보다 낮춰야 해 배치가 튄다 — 숨기면 분할 뷰가 알아서 칸을 접는다.
    private let sidebarToggle = NSButton(
        image: NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "사이드바")!,
        target: nil, action: nil)
    private var tab: WorkshopTab = .installed
    private var localItems: [WallpaperItem] = []
    /// 탭마다 검색어를 따로 기억한다. 라이브러리에서 친 말이 창작마당으로
    /// 넘어가면 엉뚱한 결과가 나온다.
    private var searchTexts: [WorkshopTab: String] = [:]

    private var sidebar: WorkshopSidebarView!
    private var filterState = WorkshopFilterState()

    private let collectionView = DoubleClickCollectionView()
    private let gridLayout = WorkshopGridLayout()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let cellSizeSlider = NSSlider()
    /// 오른쪽 칸. `detailPanel`을 꽉 채워 넣는다.
    let detailContainer = NSView()
    private let detailPanel: WorkshopDetailPanel
    /// 상세 페이지(평점·작성자) 메모리 캐시. id별로 한 번만 받는다.
    private var detailsPageCache: [String: WorkshopDetailsPage] = [:]
    /// 지금 받는 중인 상세 페이지 id들. 다운로드 진행률 줄마다 `refreshDetailPanel`이
    /// 다시 불려도 같은 id를 두 번 청하지 않는다.
    private var detailsPageInFlight: Set<String> = []

    private let loginButton = NSButton(title: "스팀 로그인", target: nil, action: nil)
    private let accountField = NSTextField()
    fileprivate let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    /// 격자가 비었을 때 가운데 띄우는 안내. 아래 상태 줄의 "0개"만으로는
    /// 결과가 없는 건지, 아직 읽는 중인지, 못 읽은 건지 알 수 없다.
    private let emptyMessage = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton(title: "", target: nil, action: nil)
    private lazy var emptyState: NSStackView = {
        let stack = NSStackView(views: [emptyMessage, emptyButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyMessage.alignment = .center
        emptyMessage.textColor = .secondaryLabelColor
        emptyButton.target = self
        emptyButton.action = #selector(emptyButtonTapped)
        return stack
    }()
    /// 마지막 목록 요청이 실패했을 때의 이유. 새 요청을 시작하면 지운다.
    private var loadError: String?

    /// 창작마당 항목 누적 목록. 무한 스크롤이라 페이지를 붙여 나간다
    /// (`WorkshopPaging.merge`). 탭·필터·검색·정렬이 바뀌면 통째로 비운다.
    fileprivate var items: [WorkshopItem] = []
    /// `NSCache`로 개수·바이트 상한을 둔다 — 큰 GIF를 여럿 지나가도 메모리가 안 터진다.
    /// 개수만으로는 부족했다: 창작마당 미리보기는 몇 MB짜리 GIF가 흔해 500개쯤
    /// 스크롤하니 1GB를 넘겼다. 밀려난 것은 칸이 다시 보일 때 새로 받는다.
    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1024 * 1024  // 압축 크기 기준 — 풀린 프레임까지 치면 실제로는 몇 배
        return cache
    }()
    /// 받는 중인 썸네일 id. 같은 칸이 여러 번 그려져도 한 번만 받는다.
    private var thumbnailsInFlight: Set<String> = []
    /// 진행 중인 목록 요청 세대. 필터를 빠르게 바꿀 때 늦게 온 옛 페이지가
    /// 새 결과에 섞이는 것을 막는다.
    private var loadGeneration = 0
    private var isDownloading = false
    private var isLoadingPage = false
    /// 다음에 받을 창작마당 페이지 번호. 1부터 센다.
    private var nextPage = 1
    /// 스팀이 빈 목록을 준 적이 있으면 끝난 것이다 — 더 요청하지 않는다.
    private var reachedEnd = false
    /// 클라이언트 OR 필터에 걸려 새 칸이 0개였던 연속 횟수.
    private var consecutiveEmptyPages = 0
    /// 지금 받는 중인 항목과 진행률(0...1). 격자 칸의 진행 막대에 쓴다.
    private var downloadingID: String?
    private var downloadFraction: Double = 0

    /// 진행률 콜백이 창을 찾기 위한 자리. 창은 한 번에 하나만 뜬다.
    private static weak var current: WorkshopWindowController?

    init(
        installer: WorkshopInstaller,
        store: UserPropertyStore,
        libraryItems: @escaping () -> [WallpaperItem],
        onApply: @escaping (WallpaperItem) -> Void,
        currentItemID: @escaping () -> String?,
        onLibraryChanged: @escaping () -> Void,
        onPropertiesChanged: @escaping () -> Void
    ) {
        self.installer = installer
        self.libraryItems = libraryItems
        self.onApply = onApply
        self.currentItemID = currentItemID
        self.onLibraryChanged = onLibraryChanged
        // 설정 창과 같은 저장소·같은 콜백 — 편집이 같은 곳에 저장되고 켜진
        // 배경화면에 그 즉시 반영된다.
        self.detailPanel = WorkshopDetailPanel(
            editor: PropertyEditorView(store: store, onChanged: onPropertiesChanged, showsTitle: false))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "창작마당"
        window.minSize = NSSize(width: 980, height: 600)
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
        detailPanel.onPrimary = { [weak self] in self?.activateSelected() }
        detailPanel.onRemove = { [weak self] in self?.removeSelected() }
        Self.current = self
        showTab(.installed)
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    // MARK: - 화면 구성

    private func makeContentView() -> NSView {
        sidebar = WorkshopSidebarView(initial: filterState) { [weak self] newState in
            self?.filterChanged(to: newState)
        }

        let middle = makeMiddleColumn()

        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailPanel)
        NSLayoutConstraint.activate([
            detailPanel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            detailPanel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailPanel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(middle)
        splitView.addArrangedSubview(detailContainer)
        splitView.translatesAutoresizingMaskIntoConstraints = false

        for view in [sidebar, middle, detailContainer] {
            view?.translatesAutoresizingMaskIntoConstraints = false
        }
        // 낮은 우선순위로 시작 너비만 제안한다 — required로 두면 NSSplitView가
        // 드래그·접기 때 스스로 거는 제약과 부딪혀 도로 튕기거나 "동시에
        // 만족시킬 수 없다"는 경고를 낸다. 실제 고정은 holding priority가 한다.
        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 220)
        sidebarWidth.priority = .defaultHigh
        sidebarWidth.isActive = true
        let detailWidth = detailContainer.widthAnchor.constraint(equalToConstant: 340)
        detailWidth.priority = .defaultHigh
        detailWidth.isActive = true
        // 위 340은 그냥 "바랐으면 하는" 값이라 항목을 고르면 미리보기·제목·태그
        // 같은 내용이 요구하는 폭에 밀려 쉽게 어겨진다 — 필수(required)로
        // 최소·최대를 박아 어떤 내용이 와도 300~420을 벗어나지 못하게 한다.
        NSLayoutConstraint.activate([
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            detailContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        // 사이드바·상세는 창이 늘어나도 그대로다 — 늘어난 자리는 격자가 가져간다.
        splitView.setHoldingPriority(.dragThatCannotResizeWindow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.dragThatCannotResizeWindow, forSubviewAt: 2)

        let root = NSView()
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    private func makeMiddleColumn() -> NSView {
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)

        searchField.placeholderString = "검색"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // 검색은 Enter로만 돈다. 글자마다 요청하면 스팀에 부담이고 결과가 튄다.
        searchField.sendsWholeSearchString = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 좁은 창에서 다른 도구(정렬·칸 크기)에 밀려 찌그러지던 것을 막는다. 더 크게
        // 잡으면 도구 줄이 창 최소 폭(980)을 넘겨 창이 그만큼 안 줄어든다.
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        for sort in WorkshopSort.allCases { sortPopup.addItem(withTitle: sort.label) }
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)

        let savedCellSize = UserDefaults.standard.double(forKey: Self.cellSizeKey)
        cellSizeSlider.minValue = Double(Self.minCellSize)
        cellSizeSlider.maxValue = Double(Self.maxCellSize)
        cellSizeSlider.doubleValue = savedCellSize > 0 ? savedCellSize : 220
        cellSizeSlider.target = self
        cellSizeSlider.action = #selector(cellSizeChanged)
        cellSizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        accountField.placeholderString = "스팀 계정 이름"
        // 스팀 앱이 이미 로그인해 둔 계정 이름을 미리 채운다. 비밀번호가 아니다.
        accountField.stringValue = UserDefaults.standard.string(forKey: Self.accountKey)
            ?? SteamCmdClient.detectAccountName() ?? ""
        accountField.target = self
        accountField.action = #selector(saveAccount)
        accountField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        loginButton.target = self
        loginButton.action = #selector(openLoginTerminal)

        // 계정·로그인은 창작마당 탭에서만 뜻이 있다. 위쪽 줄 오른쪽에 둔다.
        let accountRow = NSStackView(views: [
            accountLabel, accountField, loginButton,
        ])
        accountRow.orientation = .horizontal
        accountRow.spacing = 8

        let spacer = NSView()
        // 스택 안에서 늘어날 유일한 뷰가 돼야 한다 — 다른 쪽은 hugging이
        // 기본값(250)이라 그대로 두면 동률로 tabControl이 대신 늘어난다.
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        sidebarToggle.bezelStyle = .texturedRounded
        sidebarToggle.isBordered = false
        sidebarToggle.toolTip = "필터 사이드바 숨기기/보이기"
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebar)
        let topRow = NSStackView(views: [sidebarToggle, tabControl, spacer, accountRow])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.distribution = .fill

        let gridToolsRow = NSStackView(views: [
            searchField, sortPopup,
            NSTextField(labelWithString: "칸 크기"), cellSizeSlider,
        ])
        gridToolsRow.orientation = .horizontal
        gridToolsRow.spacing = 8

        let top = NSStackView(views: [topRow, gridToolsRow])
        top.orientation = .vertical
        top.spacing = 8
        top.alignment = .leading
        topRow.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        gridToolsRow.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        // 격자로 보여 준다. 왼쪽부터 채우는 자체 배치라 창 너비가 바뀌면
        // 한 줄에 들어가는 개수가 알아서 바뀐다. 배경화면은 그림이 본체라
        // 표보다 격자가 맞다.
        gridLayout.targetCellWidth = CGFloat(cellSizeSlider.doubleValue)
        collectionView.collectionViewLayout = gridLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            WorkshopGridItem.self,
            forItemWithIdentifier: WorkshopGridItem.identifier)

        collectionView.onActivate = { [weak self] indexPath in
            self?.activate(at: indexPath)
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // bounds 변화를 지켜봐 무한 스크롤 다음 페이지를 미리 청한다.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor

        // 적용·지우기·받기는 상세 패널 버튼이 한다(Return도 그쪽 주 버튼).
        let bottom = NSStackView(views: [spinner, statusLabel])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        let stack = NSStackView(views: [top, scrollView, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        // 스크롤 뷰 안에 넣으면 스크롤 뷰가 제 하위 뷰를 직접 배치해 제약이 안 먹는다
        // — 형제로 두고 가운데만 맞춘다.
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
        return root
    }

    // MARK: - 탭·필터

    @objc private func tabChanged() {
        showTab(WorkshopTab(rawValue: tabControl.selectedSegment) ?? .installed)
    }

    /// 탭에 따라 무엇을 보여 주고 어떤 조작을 열지 정한다.
    /// 밖에서 탭을 고른다(확인용 환경 변수가 쓴다).
    func selectTab(_ next: WorkshopTab) {
        tabControl.selectedSegment = next.rawValue
        showTab(next)
    }

    private func showTab(_ next: WorkshopTab) {
        // 떠나는 탭의 검색어를 기억하고, 가는 탭의 것을 되살린다.
        searchTexts[tab] = searchField.stringValue
        tab = next
        searchField.stringValue = searchTexts[next] ?? ""
        tabControl.selectedSegment = next.rawValue

        let isInstalled = next == .installed
        // 라이브러리는 내가 가진 것이라 정렬·계정이 필요 없다.
        for control in [sortPopup, accountLabel, accountField, loginButton] {
            control.isHidden = isInstalled
        }
        searchField.placeholderString = isInstalled ? "라이브러리에서 찾기" : "창작마당 검색"
        sidebar.showsHideInstalled = !isInstalled

        if isInstalled {
            reloadLibrary()
        } else {
            resetAndLoadFirstPage()
        }
    }

    /// 사이드바가 바뀌면 필터를 갱신하고 목록을 처음부터 다시 받는다(세대 번호 증가).
    /// 설치됨 탭은 네트워크가 필요 없다 — 로컬 목록을 다시 거르기만 한다.
    private func filterChanged(to newState: WorkshopFilterState) {
        filterState = newState
        if tab == .installed {
            refreshTable()
            // 검색처럼 개수도 고친다 — 안 그러면 1칸만 보여도 "5개"로 남는다.
            setBusy(false, status: "\(displayedEntries.count)개")
        } else {
            resetAndLoadFirstPage()
        }
    }

    @objc private func searchChanged() {
        if tab == .installed {
            refreshTable()
            setBusy(false, status: "\(displayedEntries.count)개")
        } else {
            resetAndLoadFirstPage()
        }
    }

    @objc private func toggleSidebar() {
        sidebar.isHidden.toggle()
    }

    @objc private func sortChanged() {
        guard tab == .browse else { return }
        resetAndLoadFirstPage()
    }

    @objc private func cellSizeChanged() {
        UserDefaults.standard.set(cellSizeSlider.doubleValue, forKey: Self.cellSizeKey)
        gridLayout.targetCellWidth = CGFloat(cellSizeSlider.doubleValue)
    }

    // MARK: - 목록 (창작마당 · 무한 스크롤)

    /// 필터·검색·정렬·탭이 바뀔 때마다 여기로 온다. 세대 번호를 올려 옛 응답을
    /// 무효로 만들고, 누적 목록을 비운 뒤 첫 페이지부터 다시 받는다.
    private func resetAndLoadFirstPage() {
        loadGeneration += 1
        // 옛 세대의 in-flight 요청은 위 증가로 이미 무효다 — 그 요청이 끝나도
        // `guard generation == loadGeneration`에 걸려 되돌아오므로 여기서
        // 미리 꺼 둬야 한다. 안 그러면 그 요청이 절대 안 꺼서 다음 페이지
        // 요청이 영원히 무시된다.
        isLoadingPage = false
        nextPage = 1
        reachedEnd = false
        consecutiveEmptyPages = 0
        items = []
        refreshTable()
        loadNextPage()
    }

    @objc private func scrollViewDidScroll() {
        guard tab == .browse, !isLoadingPage, !reachedEnd else { return }
        let visibleBottom = scrollView.documentVisibleRect.maxY
        // 격자의 실측 내용 높이. `collectionView.frame`은 스크롤이 막
        // 바뀐 직후에는 아직 갱신 전이라 낡은 값을 줄 수 있다.
        let contentHeight = collectionView.collectionViewLayout?
            .collectionViewContentSize.height ?? collectionView.frame.height
        let rowHeight = Double(cellSizeSlider.doubleValue) + Double(gridLayout.spacing) + 20 // 칸 + 줄 간격 + 제목 줄
        guard WorkshopScrollPaging.shouldLoadNextPage(
            visibleBottom: Double(visibleBottom), contentHeight: Double(contentHeight),
            rowHeight: rowHeight) else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard tab == .browse, !reachedEnd, !isLoadingPage else { return }
        isLoadingPage = true
        loadError = nil
        let generation = loadGeneration
        let sort = WorkshopSort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        let filter = filterState.requestFilter
        let text = searchField.stringValue
        let requested = nextPage
        setBusy(true, status: "목록을 읽는 중…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await client.listIDs(
                    sort: sort, filter: filter, searchText: text, page: requested)
                guard generation == self.loadGeneration else { return }
                guard !ids.isEmpty else {
                    self.reachedEnd = true
                    self.isLoadingPage = false
                    self.setBusy(false, status: "\(self.items.count)개 (끝)")
                    return
                }
                let fetched = try await self.client.details(ids: ids)
                guard generation == self.loadGeneration else { return }

                let existingIDs = Set(self.items.map(\.id))
                let merged = WorkshopPaging.merge(self.items, fetched)
                let newlyAdded = merged.filter { !existingIDs.contains($0.id) }
                self.items = merged
                self.nextPage = requested + 1
                self.refreshTable()

                // 클라이언트 OR 필터 뒤 이 페이지에서 새로 보일 칸이 없으면
                // 한 번 더 다음 페이지를 청한다(연속 3회까지). 전부 중복이라
                // `newlyAdded`가 비어도 마찬가지로 빈 페이지 취급한다 — 인기
                // 정렬은 페이지 사이에 순위가 바뀌어 아예 다 겹칠 수 있다.
                let passing = newlyAdded.filter { self.itemPassesClientFilter($0) }
                self.isLoadingPage = false
                if passing.isEmpty {
                    self.consecutiveEmptyPages += 1
                    if WorkshopScrollPaging.shouldRetryAfterEmptyPage(
                        consecutiveEmptyPages: self.consecutiveEmptyPages) {
                        self.loadNextPage()
                        return
                    }
                } else {
                    self.consecutiveEmptyPages = 0
                }
                self.setBusy(false, status: "\(self.displayedEntries.count)개")
                // 화면이 아직 안 찼으면(짧은 결과라 스크롤 막대가 없는 경우)
                // bounds 변화 알림이 안 와서 다음 페이지 요청이 걸리지 않는다.
                // 레이아웃이 끝난 다음 지금 상태로 한 번 더 물어본다.
                DispatchQueue.main.async { [weak self] in self?.scrollViewDidScroll() }
            } catch {
                guard generation == self.loadGeneration else { return }
                self.isLoadingPage = false
                self.loadError = Self.describe(error)
                self.setBusy(false, status: "목록을 읽지 못했다: \(Self.describe(error))")
            }
        }
    }

    private func itemPassesClientFilter(_ item: WorkshopItem) -> Bool {
        guard filterState.matches(tags: item.tags) else { return false }
        if filterState.hideInstalled, installer.isInstalled(id: item.id) { return false }
        return true
    }

    /// 라이브러리 목록을 다시 읽는다.
    private func reloadLibrary() {
        localItems = libraryItems()
        thumbnails.removeAllObjects()
        refreshTable()
        setBusy(false, status: "\(displayedEntries.count)개")
        loadLibraryThumbnails()
    }

    /// 라이브러리 미리보기는 로컬 파일이라 네트워크가 필요 없다.
    private func loadLibraryThumbnails() {
        for item in localItems {
            guard let url = item.previewURL, let image = NSImage(contentsOf: url) else { continue }
            thumbnails.setObject(image, forKey: item.id as NSString)
        }
        collectionView.reloadData()
    }

    /// `refreshTable()`이 마지막으로 계산해 둔 화면 목록. 셀 하나 그릴 때마다
    /// `installer.isInstalled`(파일 스탯)를 새로 도는 `visibleEntries`를 다시
    /// 계산하면 무한 스크롤로 쌓인 수백 개에서 셀당 비용이 된다 — 한 번만
    /// 계산해 두고 선택·다운로드 진행률 갱신은 이 배열을 본다.
    private var displayedEntries: [GridEntry] = []

    /// 지금 탭에서 보여 줄 칸들. `displayedEntries`를 새로 채울 때만 부른다.
    private var visibleEntries: [GridEntry] {
        let current = currentItemID()
        if tab == .installed {
            let text = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            return localItems
                .filter { text.isEmpty || $0.title.lowercased().contains(text) }
                // 해상도는 project.json 어디에도 없다 — 넣은 채로 거르면 하나라도
                // 고른 순간 설치된 항목이 전부 빠진다.
                .filter { filterState.matches(tags: $0.filterTags, ignoring: [.resolution]) }
                .map { GridEntry(id: $0.id, title: $0.title, installed: true,
                                 isCurrent: $0.id == current) }
        }
        return items
            .filter(itemPassesClientFilter)
            .map { GridEntry(id: $0.id, title: $0.title, installed: installer.isInstalled(id: $0.id),
                             isCurrent: $0.id == current) }
    }

    /// 라이브러리에서 고른 배경화면.
    private var selectedLibraryItem: WallpaperItem? {
        guard tab == .installed, let id = selectedEntry?.id else { return nil }
        return localItems.first { $0.id == id }
    }

    private var selectedEntry: GridEntry? {
        guard let index = collectionView.selectionIndexPaths.first?.item else { return nil }
        return index < displayedEntries.count ? displayedEntries[index] : nil
    }

    /// 지금 고른 창작마당 항목.
    private var selectedItem: WorkshopItem? {
        guard tab != .installed, let id = selectedEntry?.id else { return nil }
        return items.first { $0.id == id }
    }

    @objc private func applySelected() {
        guard let item = selectedLibraryItem else { return }
        onApply(item)
        setBusy(false, status: "\(item.title) 적용")
        // "사용 중" 표시를 새 배경화면으로 옮긴다.
        refreshTable()
    }

    /// 밖에서 항목을 고른다(확인용 환경 변수가 쓴다). 목록에 없으면 아무것도 안 한다.
    private var pendingSelectID: String?

    func selectItem(id: String) {
        // 창작마당 목록은 비동기로 오니 아직 없으면 기억해 뒀다가 목록이 오면 고른다.
        guard let index = displayedEntries.firstIndex(where: { $0.id == id }) else {
            pendingSelectID = id
            return
        }
        pendingSelectID = nil
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
        selectionDidChange()
    }

    @objc private func refreshTable() {
        // `reloadData()`는 선택을 잃는다(무한 스크롤 다음 페이지·다운로드 뒤
        // 갱신마다 불린다) — 골라 둔 id가 새 목록에도 있으면 되살린다. 안 그러면
        // 다운로드가 끝나자마자 상세 패널이 "적용"으로 안 바뀌고 빈 채로 간다.
        let pending = pendingSelectID.flatMap { id in visibleEntries.contains { $0.id == id } ? id : nil }
        if pending != nil { pendingSelectID = nil }
        let keepID = selectedEntry?.id ?? pending
        displayedEntries = visibleEntries
        collectionView.reloadData()
        if let keepID, let index = displayedEntries.firstIndex(where: { $0.id == keepID }) {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.selectionIndexPaths = [indexPath]
            // 밖에서 고른 항목은 화면 밖일 수 있다 — 보이게 내린다.
            if pending != nil {
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
            }
        }
        selectionDidChange()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = displayedEntries.isEmpty && !isLoadingPage
        emptyState.isHidden = !empty
        guard empty else { return }
        if let loadError, tab == .browse {
            emptyMessage.stringValue = "목록을 읽지 못했다\n\(loadError)"
            emptyButton.title = "다시 시도"
        } else {
            emptyMessage.stringValue = tab == .installed && localItems.isEmpty
                ? "받은 배경화면이 없다\n창작마당 탭에서 받아 온다"
                : "맞는 배경화면이 없다\n검색어나 필터를 바꿔 본다"
            // 검색어도 같이 지우므로 있으면 그렇다고 적는다.
            emptyButton.title = searchField.stringValue.isEmpty ? "필터 초기화" : "검색·필터 초기화"
        }
        // 설치된 게 아예 없으면 거를 것도 없다.
        emptyButton.isHidden = tab == .installed && localItems.isEmpty
    }

    @objc private func emptyButtonTapped() {
        if loadError != nil, tab == .browse {
            loadNextPage()
            return
        }
        searchField.stringValue = ""
        var reset = filterState
        reset.reset()
        sidebar.setState(reset)
        filterChanged(to: reset)
    }

    /// 칸이 화면에 나올 때(또는 상세 패널이 필요할 때) 그 항목 것만 받는다.
    /// 예전엔 페이지마다 쌓인 목록 전체를 훑어, 캐시에서 밀려난 수백 개를 매번 다시 받았다.
    /// 캐시는 id로 찾으니 필터가 바뀌어도(세대가 달라도) 그대로 써도 된다.
    private func requestThumbnail(for id: String) {
        guard tab == .browse, thumbnails.object(forKey: id as NSString) == nil,
              let url = items.first(where: { $0.id == id })?.previewURL,
              thumbnailsInFlight.insert(id).inserted
        else { return }
        Task { [weak self] in
            let fetched = try? await URLSession.shared.data(from: url)
            guard let self else { return }
            self.thumbnailsInFlight.remove(id)
            guard let (data, _) = fetched, let image = NSImage(data: data) else { return }
            self.thumbnails.setObject(image, forKey: id as NSString, cost: data.count)
            // 그 칸만 다시 그린다. 전체 reload는 선택을 잃는다.
            if let index = self.displayedEntries.firstIndex(where: { $0.id == id }) {
                self.reloadItemKeepingSelection(IndexPath(item: index, section: 0))
            }
            // 이미 골라 둔 항목이면 상세 패널의 빈 미리보기도 채운다.
            if self.selectedEntry?.id == id { self.refreshDetailPanel() }
        }
    }

    // MARK: - 선택·활성화

    /// 오른쪽 상세 패널에 지금 고른 항목을 알린다.
    private func selectionDidChange() {
        refreshDetailPanel()
    }

    /// 지금 탭·선택에 맞춰 상세 패널을 다시 그린다. 창작마당 항목이고 상세
    /// 페이지(평점·작성자)를 아직 못 받았으면 백그라운드로 받아 온다.
    private func refreshDetailPanel() {
        switch tab {
        case .installed:
            guard let item = selectedLibraryItem else { detailPanel.showEmpty(); return }
            detailPanel.showInstalled(
                item: item, preview: thumbnails.object(forKey: item.id as NSString),
                isCurrent: item.id == currentItemID())
        case .browse:
            guard let item = selectedItem else { detailPanel.showEmpty(); return }
            let progress = (item.id == downloadingID) ? downloadFraction : nil
            detailPanel.showWorkshop(
                item: item, preview: thumbnails.object(forKey: item.id as NSString),
                page: detailsPageCache[item.id],
                installed: installer.isInstalled(id: item.id),
                isCurrent: item.id == currentItemID(), progress: progress)
            if detailsPageCache[item.id] == nil {
                loadDetailsPage(for: item.id)
            }
            requestThumbnail(for: item.id)
        }
    }

    /// 평점·작성자는 목록 API에 없다 — 상세 페이지를 따로 긁는다. 실패해도
    /// 나머지 패널은 이미 떠 있으니 조용히 넘어간다(Review Focus 3).
    private func loadDetailsPage(for id: String) {
        // 다운로드 진행률 줄마다 `refreshDetailPanel`이 다시 부르므로, 이미
        // 청한 id면 새로 청하지 않는다 — 안 그러면 같은 페이지를 초당 여러 번 받는다.
        guard detailsPageInFlight.insert(id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.detailsPageInFlight.remove(id) }
            guard let page = try? await self.client.detailsPage(id: id) else { return }
            // 캐시는 선택이 바뀌었어도 채운다 — 다시 고르면 또 받을 필요가 없다.
            self.detailsPageCache[id] = page
            // 받는 사이 다른 항목을 골랐으면 다시 그리지 않는다 — 화면과 안 맞는다.
            guard self.selectedItem?.id == id else { return }
            self.refreshDetailPanel()
        }
    }

    /// 더블클릭 훅. 창작마당 탭은 이미 설치된 항목이면 적용, 아니면 기존
    /// 다운로드 흐름을 그대로 부른다. 설치됨 탭은 기존 적용 흐름이다.
    /// 상세 패널의 "받기/적용" 버튼도 같은 메서드로 연결한다.
    private func activateSelected() {
        guard let entry = selectedEntry else { return }
        switch tab {
        case .installed:
            applySelected()
        case .browse:
            if entry.installed, let local = libraryItems().first(where: { $0.id == entry.id }) {
                onApply(local)
                setBusy(false, status: "\(local.title) 적용")
                refreshTable()
            } else {
                download()
            }
        }
    }

    private func activate(at indexPath: IndexPath) {
        collectionView.selectionIndexPaths = [indexPath]
        selectionDidChange()
        activateSelected()
    }

    // MARK: - 다운로드

    @objc private func saveAccount() {
        let trimmed = accountField.stringValue.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: Self.accountKey)
    }

    @objc private func download() {
        guard !isDownloading else { return }
        guard let item = selectedItem else { return }

        saveAccount()
        let account = accountField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else {
            presentLoginHelp(account: nil)
            return
        }
        guard let executable = SteamCmdClient.locateExecutable() else {
            present(title: "steamcmd가 없다",
                    message: "터미널에서 `brew install --cask steamcmd`로 설치한 뒤 다시 시도하세요.")
            return
        }

        let steam = SteamCmdClient(
            executable: executable, installDirectory: installer.downloadRoot)
        isDownloading = true
        downloadingID = item.id
        downloadFraction = 0
        setBusy(true, status: "\(item.title) 받는 중…")
        // steamcmd는 처음 몇 초 자기 업데이트만 확인해 진행률 줄이 안 온다 — 그 사이
        // 칸·패널이 "받기" 그대로면 받는지 모르고 또 누른다. 시작하자마자 받는 중으로 그린다.
        reloadDownloadingItem()

        Task { [weak self] in
            // 진행률 줄은 임의 스레드에서 온다. 창을 직접 만지지 않고 메인으로 넘긴다.
            // self를 클로저에 가두면 Sendable 검사에 걸리므로 갱신만 하는 함수를 넘긴다.
            let report: @Sendable (String) -> Void = { line in
                // steamcmd가 진행률을 이 모양으로 뱉는다:
                // "Downloading item 123 ...", "Update state (0x61) downloading, progress: 42.11"
                guard line.contains("%") || line.contains("progress")
                        || line.contains("Downloading") else { return }
                Task { @MainActor in
                    guard let controller = WorkshopWindowController.current else { return }
                    controller.statusLabel.stringValue = String(line.prefix(70))
                    if let fraction = Self.progressFraction(fromLine: line) {
                        controller.downloadFraction = fraction
                        controller.reloadDownloadingItem()
                    }
                }
            }
            let installer = self?.installer
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    let folder = try steam.download(workshopID: item.id, login: account, progress: report)
                    // 프리셋 항목은 알맹이가 다른 항목에 있다. 같이 받아야 열린다.
                    if let dependency = Self.dependencyID(inProjectAt: folder),
                       installer.map({ !$0.isInstalled(id: dependency) }) ?? true {
                        report("Downloading dependency \(dependency) ...")
                        try steam.download(workshopID: dependency, login: account, progress: report)
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.isDownloading = false
            self.downloadingID = nil
            switch result {
            case .success:
                do {
                    try self.installer.link(id: item.id)
                    self.onLibraryChanged()
                    self.setBusy(false, status: "\(item.title) 추가됨")
                    if self.tab == .installed { self.reloadLibrary() }
                    self.refreshTable()
                } catch {
                    self.setBusy(false, status: "받았지만 라이브러리에 넣지 못했다")
                    self.present(title: "라이브러리에 넣지 못했다",
                                 message: Self.describe(error))
                }
            case .failure(let error):
                self.setBusy(false, status: "받지 못했다")
                if case SteamCmdError.loginRequired = error {
                    self.presentLoginHelp(account: account)
                } else {
                    self.present(title: "받지 못했다", message: Self.describe(error))
                }
            }
        }
    }

    /// 진행률 줄에서 퍼센트를 뽑아 0...1로 돌려준다. 못 읽으면 nil — 상태 글은
    /// 그래도 보이니 실패해도 사용자에게 손해는 없다.
    private static func progressFraction(fromLine line: String) -> Double? {
        guard let range = line.range(of: #"progress: ([\d.]+)"#, options: .regularExpression) else {
            return nil
        }
        let numberPart = line[range].split(separator: " ").last.map(String.init) ?? ""
        guard let value = Double(numberPart) else { return nil }
        return min(1, max(0, value / 100))
    }

    /// 진행률 줄마다 온다 — 칸을 통째로 다시 그리면 깜빡이고 호버 애니메이션도
    /// 끊긴다. 이미 화면에 있는 칸이면 진행 막대만 고쳐 그린다.
    /// `reloadItems`는 그 칸이 골라져 있으면 선택을 푼다 — 썸네일이 늦게 오면
    /// 고른 항목이 풀려 상세 패널의 미리보기·평점 갱신이 버려진다.
    private func reloadItemKeepingSelection(_ indexPath: IndexPath) {
        let kept = collectionView.selectionIndexPaths
        collectionView.reloadItems(at: [indexPath])
        collectionView.selectionIndexPaths = kept
    }

    private func reloadDownloadingItem() {
        guard let id = downloadingID else { return }
        if let index = displayedEntries.firstIndex(where: { $0.id == id }) {
            let indexPath = IndexPath(item: index, section: 0)
            if let cell = collectionView.item(at: indexPath) as? WorkshopGridItem {
                cell.updateProgress(downloadFraction)
            } else {
                reloadItemKeepingSelection(indexPath)
            }
        }
        // 지금 받는 항목이 고른 항목이면 상세 패널의 진행 막대도 같이 간다.
        if tab == .browse, selectedItem?.id == id {
            refreshDetailPanel()
        }
    }

    /// 받은 폴더의 project.json이 다른 항목에 딸린 프리셋이면 그 번호.
    nonisolated static func dependencyID(inProjectAt folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dependency = json["dependency"] as? String,
              !dependency.isEmpty, dependency.allSatisfy(\.isNumber) else { return nil }
        return dependency
    }

    /// 자격 증명은 이 앱이 만지지 않는다. 사용자가 터미널에서 한 번 로그인해야 한다.
    ///
    /// 비밀번호 프롬프트에는 진짜 TTY가 필요하다. 앱 안에서 받으면 비밀번호를
    /// 우리가 만지게 되고, 그건 배경화면 앱이 할 일이 아니다. 대신 터미널을 열어
    /// 명령까지 넣어 준다 — 사용자는 비밀번호만 치면 된다.
    @objc private func openLoginTerminal() {
        saveAccount()
        let account = accountField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else {
            present(title: "계정 이름이 필요하다",
                    message: "스팀 계정 이름을 먼저 넣으세요. 비밀번호가 아니라 계정 이름입니다.")
            return
        }
        // 계정 이름이 그대로 셸에 들어가므로 스팀이 허용하는 글자만 남긴다.
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safe == account else {
            present(title: "계정 이름에 쓸 수 없는 글자가 있다",
                    message: "영문·숫자·밑줄·붙임표만 쓸 수 있습니다.")
            return
        }
        let script = "tell application \"Terminal\"\n"
            + "activate\n"
            + "do script \"steamcmd +login \(safe)\"\n"
            + "end tell"
        guard let apple = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if error != nil {
            present(title: "터미널을 열지 못했다",
                    message: "터미널에서 직접 `steamcmd +login \(safe)`를 실행하세요.")
            return
        }
        statusLabel.stringValue = "터미널에서 로그인한 뒤 다시 받기를 누르세요"
    }

    private func presentLoginHelp(account: String?) {
        let name = account?.isEmpty == false ? account! : "<계정이름>"
        let alert = NSAlert()
        alert.messageText = "스팀 로그인이 필요하다"
        alert.informativeText = """
            로그인 세션이 만료됐습니다. 터미널에서 한 번 로그인하면 다시 이어집니다.
            비밀번호와 Steam Guard 코드를 터미널이 직접 받습니다 — 이 앱은 비밀번호를 \
            저장하지도 다루지도 않습니다.

                steamcmd +login \(name)
            """
        alert.addButton(withTitle: "터미널 열기")
        alert.addButton(withTitle: "닫기")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openLoginTerminal() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(alert.runModal()) }
    }

    // MARK: - 잡동사니

    private func setBusy(_ busy: Bool, status: String) {
        statusLabel.stringValue = status
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateEmptyState()
    }

    /// 라이브러리에서 링크만 걷는다. 받아 둔 원본은 남겨 다시 받지 않아도 되게 한다.
    @objc private func removeSelected() {
        guard let item = selectedEntry else { return }
        // 받아 둔 원본까지 지운다. 되돌릴 수 없으니 한 번 묻는다 —
        // 다시 받으면 되지만 씬 하나가 1GB를 넘기도 한다.
        let alert = NSAlert()
        alert.messageText = "\(item.title)을(를) 지울까요?"
        alert.informativeText = "라이브러리에서 빼고 받아 둔 파일도 지웁니다. "
            + "필요하면 창작마당에서 다시 받을 수 있습니다."
        // 켜진 것을 지우면 지금은 계속 보이다가 다음에 켤 때 되살릴 게 없다 — 미리 알린다.
        if item.id == currentItemID() {
            alert.informativeText += "\n\n지금 배경화면으로 쓰는 중입니다. 지우면 다음에 앱을 켤 때 "
                + "이 배경화면이 뜨지 않습니다."
        }
        let deleteButton = alert.addButton(withTitle: "지우기")
        let cancelButton = alert.addButton(withTitle: "취소")
        // 되돌릴 수 없으니 Return으로 지워지면 안 된다 — 기본(Return)은 취소가 받고,
        // 지우기는 빨갛게만 둔다.
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            switch try installer.remove(id: item.id) {
            case .deletedDownload:
                setBusy(false, status: "\(item.title) 지웠다")
            case .unlinkedOnly:
                // 우리가 받은 게 아니라 사용자가 직접 넣은 폴더다. 링크만 걷었다.
                setBusy(false, status: "\(item.title) 뺐다 (직접 넣은 폴더라 파일은 남겼다)")
            case nil:
                setBusy(false, status: "라이브러리에 없다")
                return
            }
            onLibraryChanged()
            if tab == .installed { reloadLibrary() }
            refreshTable()
        } catch {
            present(title: "지우지 못했다", message: Self.describe(error))
        }
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SteamCmdError.notInstalled: return "steamcmd가 설치되어 있지 않다"
        case SteamCmdError.loginRequired(let account): return "\(account) 계정 로그인이 필요하다"
        case SteamCmdError.downloadFailed(_, let output): return output
        case SteamCmdError.invalidWorkshopID(let id): return "잘못된 아이템 번호: \(id)"
        case WorkshopError.badResponse(let code): return "스팀 응답 오류 \(code)"
        case WorkshopError.malformedPayload: return "스팀 응답을 읽지 못했다"
        default: return "\(error)"
        }
    }
}

extension WorkshopWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
        -> Int { displayedEntries.count }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(
            withIdentifier: WorkshopGridItem.identifier, for: indexPath)
        let list = displayedEntries
        if let grid = cell as? WorkshopGridItem, indexPath.item < list.count {
            let entry = list[indexPath.item]
            let progress = (entry.id == downloadingID) ? downloadFraction : nil
            let image = thumbnails.object(forKey: entry.id as NSString)
            grid.configure(entry: entry, image: image, downloadProgress: progress)
            if image == nil { requestThumbnail(for: entry.id) }
        }
        return cell
    }

    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) { selectionDidChange() }

    func collectionView(
        _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
    ) { selectionDidChange() }
}

extension WorkshopWindowController: @preconcurrency NSSplitViewDelegate {
    /// 사이드바는 접을 수 있다(구분선 더블클릭). 상세 칸은 늘 보이는 편이 낫다
    /// — 아직 선택한 항목이 없다는 안내조차 사라지면 혼란스럽다.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === splitView.arrangedSubviews.first
    }

    func splitView(
        _ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt dividerIndex: Int
    ) -> Bool {
        dividerIndex == 0
    }
}

/// 칸 더블클릭·Return을 알리는 격자.
///
/// `NSClickGestureRecognizer`를 붙였더니 여러 번에 한 번꼴로 더블클릭을 놓쳤다 —
/// 컬렉션 뷰가 mouseDown에서 선택·드래그 추적 루프를 돌며 이벤트를 먼저 먹는다.
/// 그 루프가 끝난 뒤 이벤트의 clickCount를 직접 본다.
final class DoubleClickCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) { onActivate?(indexPath) }
    }

    /// Return은 더블클릭과 같다. 격자가 키를 받는 동안엔 Return이 상세 패널
    /// 기본 버튼까지 가지 않고 여기서 삼켜진다.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return, 숫자판 Enter
        if isReturn, let indexPath = selectionIndexPaths.first {
            onActivate?(indexPath)
        } else {
            super.keyDown(with: event)
        }
    }
}
