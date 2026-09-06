import AppKit
import WallflowKit

/// 격자에 그리는 한 칸. 라이브러리 항목과 창작마당 항목을 같은 모양으로 보여 준다.
struct GridEntry {
    let id: String
    let title: String
    let detail: String
    let installed: Bool
}

/// 창을 무엇으로 채우는지.
enum WorkshopTab: Int, CaseIterable {
    /// 받아 둔 배경화면. 먼저 보이는 것이 맞다 — 매일 쓰는 것은 이쪽이다.
    case library
    /// 창작마당 검색.
    case search
    /// 창작마당 둘러보기.
    case browse

    var label: String {
        switch self {
        case .library: return "내 라이브러리"
        case .search: return "검색"
        case .browse: return "창작마당"
        }
    }
}

/// 배경화면을 고르고, 창작마당에서 받아 라이브러리에 넣는 창.
///
/// 목록은 스팀에서 읽고, 다운로드는 steamcmd가 한다. 자격 증명은 이 앱이 만지지
/// 않는다 — steamcmd가 비밀번호와 Steam Guard를 대화식으로만 받으므로, 사용자가
/// 터미널에서 한 번 로그인해 캐시를 만들어야 한다. 그 상태를 안내로 알린다.
@MainActor
final class WorkshopWindowController: NSWindowController {
    /// steamcmd 로그인에 쓸 계정 이름. 비밀번호는 저장하지 않는다.
    private static let accountKey = "wallflow.steamAccount"

    private let client = WorkshopClient()
    private let installer: WorkshopInstaller
    private let onLibraryChanged: () -> Void
    /// 라이브러리 목록을 읽어 오는 곳.
    private let libraryItems: () -> [WallpaperItem]
    /// 라이브러리에서 고른 것을 배경화면으로 건다.
    private let onApply: (WallpaperItem) -> Void

    private let tabControl = NSSegmentedControl(
        labels: WorkshopTab.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let applyButton = NSButton(title: "배경화면으로 지정", target: nil, action: nil)
    private var tab: WorkshopTab = .library
    private var localItems: [WallpaperItem] = []
    /// 탭마다 검색어를 따로 기억한다. 라이브러리에서 친 말이 창작마당으로
    /// 넘어가면 엉뚱한 결과가 나온다.
    private var searchTexts: [WorkshopTab: String] = [:]
    /// 이미 받아 온 페이지. 뒤로 갈 때 다시 요청하지 않는다.
    private var pageCache: [String: [WorkshopItem]] = [:]
    /// 미리 받아 두는 작업. 탭이나 검색어가 바뀌면 버린다.
    private var prefetch: Task<Void, Never>?

    private let collectionView = NSCollectionView()
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let kindPopup = NSPopUpButton()
    private let genrePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let ratingPopup = NSPopUpButton()
    private let hideInstalledCheckbox =
        NSButton(checkboxWithTitle: "받은 것 숨기기", target: nil, action: nil)
    private let loginButton = NSButton(title: "스팀 로그인", target: nil, action: nil)
    private let prevButton = NSButton(title: "◀", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "1")
    private let removeButton = NSButton(title: "라이브러리에서 빼기", target: nil, action: nil)
    private let accountField = NSTextField()
    fileprivate let statusLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "받아서 추가", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    fileprivate var items: [WorkshopItem] = []
    fileprivate var thumbnails: [String: NSImage] = [:]
    /// 진행 중인 목록 요청. 검색어를 빠르게 바꿀 때 옛 응답이 늦게 도착해
    /// 새 결과를 덮어쓰는 것을 막는다.
    private var loadGeneration = 0
    private var isDownloading = false
    /// 1부터 센다. 스팀 목록의 페이지 번호다.
    private var page = 1

    /// 진행률 콜백이 창을 찾기 위한 자리. 창은 한 번에 하나만 뜬다.
    private static weak var current: WorkshopWindowController?

    init(
        installer: WorkshopInstaller,
        libraryItems: @escaping () -> [WallpaperItem],
        onApply: @escaping (WallpaperItem) -> Void,
        onLibraryChanged: @escaping () -> Void
    ) {
        self.installer = installer
        self.libraryItems = libraryItems
        self.onApply = onApply
        self.onLibraryChanged = onLibraryChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Wallflow"
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
        Self.current = self
        showTab(.library)
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    // MARK: - 화면 구성

    private func makeContentView() -> NSView {
        let root = NSView()

        searchField.placeholderString = "검색"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // 검색은 Enter로만 돈다. 글자마다 요청하면 스팀에 부담이고 결과가 튄다.
        searchField.sendsWholeSearchString = true

        for sort in WorkshopSort.allCases { sortPopup.addItem(withTitle: sort.label) }
        sortPopup.target = self
        sortPopup.action = #selector(reload)

        // 조건은 **스팀에** 건다. 받아 온 페이지만 거르면 "웹 배경화면"을 골라도
        // 그 페이지에 든 두어 개만 남아, 다음 페이지에 있는 것은 영영 못 본다.
        for (popup, choices) in [
            (kindPopup, WorkshopTag.kinds), (genrePopup, WorkshopTag.genres),
            (resolutionPopup, WorkshopTag.resolutions), (ratingPopup, WorkshopTag.ratings),
        ] {
            for choice in choices { popup.addItem(withTitle: choice.label) }
            popup.target = self
            popup.action = #selector(filterChanged)
        }

        hideInstalledCheckbox.state = .off
        hideInstalledCheckbox.target = self
        hideInstalledCheckbox.action = #selector(refreshTable)

        let refreshButton = NSButton(title: "새로고침", target: self, action: #selector(hardRefresh))

        prevButton.target = self
        prevButton.action = #selector(previousPage)
        nextButton.target = self
        nextButton.action = #selector(nextPage)
        pageLabel.alignment = .center
        pageLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)

        let tabRow = NSStackView(views: [
            tabControl, sortPopup, hideInstalledCheckbox,
            prevButton, pageLabel, nextButton, refreshButton,
        ])
        tabRow.orientation = .horizontal
        tabRow.spacing = 8

        // 검색창은 탭 아래 제 줄에 둔다. 위 줄에 끼우면 좁고 눈에 덜 띈다.
        // 조건 팝업도 같은 줄에 둔다 — 위 줄은 이미 정렬과 쪽 넘김으로 찼다.
        let searchRow = NSStackView(views: [
            searchField, kindPopup, genrePopup, resolutionPopup, ratingPopup,
        ])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 팝업이 늘어나면서 검색창을 돋보기만 남게 짓눌렀다. 남는 자리는
        // 검색창이 가져가되, 팝업이 먼저 제 너비를 갖는다.
        searchField.setContentCompressionResistancePriority(
            .defaultHigh, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for popup in [kindPopup, genrePopup, resolutionPopup, ratingPopup] {
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let top = NSStackView(views: [tabRow, searchRow])
        top.orientation = .vertical
        top.spacing = 8
        top.alignment = .leading
        searchRow.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        // 격자로 보여 준다. 흐름 배치라 창 너비가 바뀌면 한 줄에 들어가는 개수가
        // 알아서 바뀐다. 배경화면은 그림이 본체라 표보다 격자가 맞다.
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 216, height: 168)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            WorkshopGridItem.self,
            forItemWithIdentifier: WorkshopGridItem.identifier)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        accountField.placeholderString = "스팀 계정 이름"
        // 스팀 앱이 이미 로그인해 둔 계정 이름을 미리 채운다. 비밀번호가 아니다.
        accountField.stringValue = UserDefaults.standard.string(forKey: Self.accountKey)
            ?? SteamCmdClient.detectAccountName() ?? ""
        accountField.target = self
        accountField.action = #selector(saveAccount)
        accountField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        downloadButton.target = self
        downloadButton.action = #selector(download)
        downloadButton.keyEquivalent = "\r"

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor

        loginButton.target = self
        loginButton.action = #selector(openLoginTerminal)

        removeButton.target = self
        removeButton.action = #selector(removeSelected)

        applyButton.target = self
        applyButton.action = #selector(applySelected)
        applyButton.keyEquivalent = "\r"

        let bottom = NSStackView(views: [
            NSTextField(labelWithString: "계정:"), accountField, loginButton,
            spinner, statusLabel, removeButton, applyButton, downloadButton,
        ])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    // MARK: - 목록

    @objc private func previousPage() {
        guard page > 1, !isDownloading else { return }
        page -= 1
        loadPage()
    }

    @objc private func nextPage() {
        guard !isDownloading else { return }
        page += 1
        loadPage()
    }

    /// 검색어나 정렬이 바뀌면 첫 페이지로 돌아간다. 3페이지를 보다가 검색하면
    /// 결과가 3페이지부터 나오는 것은 사용자가 기대하는 동작이 아니다.
    @objc private func reload() {
        page = 1
        loadPage()
    }

    /// 새로고침은 캐시를 버리고 다시 받는다. 그러라고 있는 단추다.
    @objc private func hardRefresh() {
        pageCache.removeAll()
        prefetch?.cancel()
        page = 1
        loadPage()
    }

    /// 요청 하나를 가리키는 열쇠. 정렬·검색어·페이지가 같으면 같은 결과다.
    /// 지금 팝업들이 만드는 조건.
    private var currentFilter: WorkshopFilter {
        WorkshopFilter(tags: [
            (kindPopup, WorkshopTag.kinds), (genrePopup, WorkshopTag.genres),
            (resolutionPopup, WorkshopTag.resolutions), (ratingPopup, WorkshopTag.ratings),
        ].map { popup, choices in
            let index = max(0, popup.indexOfSelectedItem)
            return index < choices.count ? choices[index].tag : ""
        })
    }

    /// 조건이 바뀌면 처음 쪽부터 다시 받는다. 3쪽에서 종류를 바꾸면 그 조건의
    /// 3쪽이 뜨는데, 사용자는 자기가 못 본 1·2쪽이 있다는 걸 알 수 없다.
    @objc private func filterChanged() {
        if tab == .library {
            refreshTable()
            return
        }
        page = 1
        loadPage()
    }

    private func cacheKey(
        sort: WorkshopSort, filter: WorkshopFilter, text: String, page: Int
    ) -> String {
        "\(sort.rawValue)|\(filter.key)|\(text)|\(page)"
    }

    private func loadPage() {
        pageLabel.stringValue = "\(page)"
        prevButton.isEnabled = page > 1
        loadGeneration += 1
        let generation = loadGeneration
        let sort = WorkshopSort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        let filter = currentFilter
        let text = searchField.stringValue
        let requested = page
        let key = cacheKey(sort: sort, filter: filter, text: text, page: requested)

        // 이미 받아 둔 페이지면 바로 보여 준다. 뒤로 가기와 미리 받아 둔
        // 다음 페이지가 즉시 뜬다 — 한 페이지에 2초쯤 걸리므로 체감이 크다.
        if let cached = pageCache[key] {
            items = cached
            refreshTable()
            setBusy(false, status: "\(requested)페이지 · \(cached.count)개")
            loadThumbnails(generation: loadGeneration)
            schedulePrefetch(sort: sort, filter: filter, text: text, after: requested)
            return
        }

        setBusy(true, status: "목록을 읽는 중…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await client.listIDs(
                    sort: sort, filter: filter, searchText: text, page: requested)
                let fetched = try await client.details(ids: ids)
                // 늦게 도착한 옛 요청이 새 결과를 덮어쓰지 않게 한다.
                guard generation == self.loadGeneration else { return }
                self.pageCache[key] = fetched
                self.items = fetched
                // 썸네일은 지우지 않는다. 페이지를 오갈 때 이미 받은 그림을
                // 다시 받는 것은 낭비다.
                self.refreshTable()
                // 결과가 없으면 마지막 페이지를 지난 것이다. 되돌려 준다 —
                // 빈 화면에 갇히면 사용자가 손쓸 방법이 없다.
                if fetched.isEmpty, requested > 1 {
                    self.page = requested - 1
                    self.pageLabel.stringValue = "\(self.page)"
                    self.setBusy(false, status: "마지막 페이지다")
                    return
                }
                self.setBusy(false, status: fetched.isEmpty ? "결과가 없다"
                    : "\(requested)페이지 · \(fetched.count)개")
                self.loadThumbnails(generation: generation)
                self.schedulePrefetch(
                    sort: sort, filter: filter, text: text, after: requested)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.items = []
                self.refreshTable()
                self.setBusy(false, status: "목록을 읽지 못했다: \(Self.describe(error))")
            }
        }
    }

    /// 종류 필터의 표시 이름. 순서가 곧 팝업 순서다.
    /// 검색은 탭마다 뜻이 다르다. 라이브러리는 가진 것을 걸러내고,
    /// 창작마당은 스팀에 새로 요청한다.
    @objc private func searchChanged() {
        if tab == .library {
            refreshTable()
            setBusy(false, status: "\(visibleEntries.count)개")
        } else {
            reload()
        }
    }

    @objc private func tabChanged() {
        showTab(WorkshopTab(rawValue: tabControl.selectedSegment) ?? .library)
    }

    /// 탭에 따라 무엇을 보여 주고 어떤 조작을 열지 정한다.
    private func showTab(_ next: WorkshopTab) {
        // 떠나는 탭의 검색어를 기억하고, 가는 탭의 것을 되살린다.
        searchTexts[tab] = searchField.stringValue
        tab = next
        searchField.stringValue = searchTexts[next] ?? ""
        tabControl.selectedSegment = next.rawValue
        prefetch?.cancel()

        let isLibrary = next == .library
        // 라이브러리는 내가 가진 것이라 정렬·페이지·계정이 필요 없다.
        for control in [sortPopup, prevButton, nextButton, pageLabel,
                        hideInstalledCheckbox, accountField, loginButton] {
            control.isHidden = isLibrary
        }
        searchField.isHidden = next == .browse
        searchField.placeholderString = isLibrary ? "라이브러리에서 찾기" : "창작마당 검색"
        applyButton.isHidden = !isLibrary
        downloadButton.isHidden = isLibrary
        removeButton.isHidden = false

        if isLibrary {
            reloadLibrary()
        } else {
            // 검색 탭은 검색어가 있을 때만 요청한다. 빈 검색은 둘러보기와 같다.
            if next == .search, searchField.stringValue.trimmingCharacters(
                in: .whitespaces).isEmpty {
                items = []
                refreshTable()
                setBusy(false, status: "검색어를 넣으세요")
                return
            }
            reload()
        }
    }

    /// 다음 페이지를 미리 받아 둔다. 사용자가 ▶를 누를 때는 이미 와 있다.
    ///
    /// 목록 한 페이지에 2초쯤 걸린다(HTML 1.1초 + 메타 0.6초). 누른 뒤에 받으면
    /// 그 시간이 그대로 기다림이 된다.
    private func schedulePrefetch(
        sort: WorkshopSort, filter: WorkshopFilter, text: String, after page: Int
    ) {
        let key = cacheKey(sort: sort, filter: filter, text: text, page: page + 1)
        guard pageCache[key] == nil else { return }
        prefetch?.cancel()
        prefetch = Task { [weak self] in
            guard let self else { return }
            guard let ids = try? await client.listIDs(
                sort: sort, filter: filter, searchText: text, page: page + 1), !ids.isEmpty,
                let fetched = try? await client.details(ids: ids) else { return }
            guard !Task.isCancelled else { return }
            self.pageCache[key] = fetched
            // 그림도 미리 받아 둔다. 넘기는 순간 빈 칸이 보이지 않는다.
            for item in fetched.prefix(12) {
                guard let url = item.previewURL, self.thumbnails[item.id] == nil else { continue }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { continue }
                guard !Task.isCancelled else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    /// 라이브러리 목록을 다시 읽는다.
    private func reloadLibrary() {
        localItems = libraryItems()
        thumbnails.removeAll()
        refreshTable()
        setBusy(false, status: "\(visibleEntries.count)개")
        loadLibraryThumbnails()
    }

    /// 라이브러리 미리보기는 로컬 파일이라 네트워크가 필요 없다.
    private func loadLibraryThumbnails() {
        for item in localItems {
            guard let url = item.previewURL, let image = NSImage(contentsOf: url) else { continue }
            thumbnails[item.id] = image
        }
        collectionView.reloadData()
    }

    /// 지금 탭에서 보여 줄 칸들.
    var visibleEntries: [GridEntry] {
        if tab == .library {
            let text = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            return localItems
                .filter { text.isEmpty || $0.title.lowercased().contains(text) }
                .map { GridEntry(id: $0.id, title: $0.title,
                                 detail: $0.type.rawValue, installed: true) }
        }
        return visibleItems.map {
            GridEntry(id: $0.id, title: $0.title,
                      detail: String(format: "%@ · %.1f MB%@", $0.kind.rawValue,
                                     Double($0.sizeBytes) / 1_000_000,
                                     installer.isInstalled(id: $0.id) ? " · 이미 있음" : ""),
                      installed: installer.isInstalled(id: $0.id))
        }
    }

    /// 라이브러리에서 고른 배경화면.
    private var selectedLibraryItem: WallpaperItem? {
        guard tab == .library, let id = selectedEntry?.id else { return nil }
        return localItems.first { $0.id == id }
    }

    private var selectedEntry: GridEntry? {
        guard let index = collectionView.selectionIndexPaths.first?.item else { return nil }
        let list = visibleEntries
        return index < list.count ? list[index] : nil
    }

    @objc private func applySelected() {
        guard let item = selectedLibraryItem else { return }
        onApply(item)
        setBusy(false, status: "\(item.title) 적용")
    }

    /// 화면에 쓰는 목록. 필터는 화면에서만 건다 — 다시 요청하지 않는다.
    private var visibleItems: [WorkshopItem] {
        var list = items
        switch kindPopup.indexOfSelectedItem {
        case 1: list = list.filter { $0.kind == .scene }
        case 2: list = list.filter { $0.kind == .video }
        case 3: list = list.filter { $0.kind == .web }
        default: break
        }
        if hideInstalledCheckbox.state == .on {
            list = list.filter { !installer.isInstalled(id: $0.id) }
        }
        return list
    }

    @objc private func refreshTable() {
        collectionView.reloadData()
        updateDownloadButton()
    }

    /// 지금 고른 창작마당 항목.
    private var selectedItem: WorkshopItem? {
        guard tab != .library, let id = selectedEntry?.id else { return nil }
        return items.first { $0.id == id }
    }

    private func loadThumbnails(generation: Int) {
        for item in items {
            guard let url = item.previewURL else { continue }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                guard let self, generation == self.loadGeneration else { return }
                self.thumbnails[item.id] = image
                // 그 칸만 다시 그린다. 전체 reload는 선택을 잃는다.
                if let index = self.visibleItems.firstIndex(where: { $0.id == item.id }) {
                    self.collectionView.reloadItems(
                        at: [IndexPath(item: index, section: 0)])
                }
            }
        }
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
        setBusy(true, status: "\(item.title) 받는 중…")

        Task { [weak self] in
            // 진행률 줄은 임의 스레드에서 온다. 창을 직접 만지지 않고 메인으로 넘긴다.
            // self를 클로저에 가두면 Sendable 검사에 걸리므로 갱신만 하는 함수를 넘긴다.
            let report: @Sendable (String) -> Void = { line in
                // steamcmd가 진행률을 이 모양으로 뱉는다:
                // "Downloading item 123 ...", "Update state (0x61) downloading, progress: 42.11"
                guard line.contains("%") || line.contains("progress")
                        || line.contains("Downloading") else { return }
                Task { @MainActor in
                    WorkshopWindowController.current?.statusLabel.stringValue =
                        String(line.prefix(70))
                }
            }
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try steam.download(workshopID: item.id, login: account, progress: report)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.isDownloading = false
            switch result {
            case .success:
                do {
                    try self.installer.link(id: item.id)
                    self.onLibraryChanged()
                    self.setBusy(false, status: "\(item.title) 추가됨")
                    if self.tab == .library { self.reloadLibrary() }
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
        updateDownloadButton()
    }

    /// 라이브러리에서 링크만 걷는다. 받아 둔 원본은 남겨 다시 받지 않아도 되게 한다.
    @objc private func removeSelected() {
        guard let item = selectedEntry else { return }
        do {
            if try installer.unlink(id: item.id) {
                onLibraryChanged()
                if tab == .library { reloadLibrary() }
                setBusy(false, status: "\(item.title) 뺐다")
            } else {
                setBusy(false, status: "라이브러리에 없다")
            }
            refreshTable()
        } catch {
            present(title: "빼지 못했다", message: Self.describe(error))
        }
    }

    private func updateDownloadButton() {
        let entry = selectedEntry
        downloadButton.isEnabled = entry != nil && !isDownloading && tab != .library
        applyButton.isEnabled = selectedLibraryItem != nil
        removeButton.isEnabled = (entry?.installed ?? false) && !isDownloading
        downloadButton.title = (entry?.installed ?? false) ? "다시 받기" : "받아서 추가"
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

/// 격자 한 칸. 미리보기 그림과 제목·부제를 보여 준다.
final class WorkshopGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkshopGridItem")

    private let preview = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let box = NSView()

    override func loadView() {
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor.clear.cgColor

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [preview, nameLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            preview.heightAnchor.constraint(equalToConstant: 110),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
        ])
        view = box
    }

    func configure(entry: GridEntry, image: NSImage?) {
        preview.image = image
        nameLabel.stringValue = entry.title
        detailLabel.stringValue = entry.detail
    }

    override var isSelected: Bool {
        didSet {
            box.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            box.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }
}

extension WorkshopWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
        -> Int { visibleEntries.count }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(
            withIdentifier: WorkshopGridItem.identifier, for: indexPath)
        let list = visibleEntries
        if let grid = cell as? WorkshopGridItem, indexPath.item < list.count {
            let entry = list[indexPath.item]
            grid.configure(entry: entry, image: thumbnailImage(for: entry.id))
        }
        return cell
    }

    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) { updateDownloadButton() }

    func collectionView(
        _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
    ) { updateDownloadButton() }

    func thumbnailImage(for id: String) -> NSImage? { thumbnails[id] }
}
