import AppKit
import WallflowKit

/// 창작마당을 둘러보고 받아서 라이브러리에 넣는 창.
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

    private let collectionView = NSCollectionView()
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let kindPopup = NSPopUpButton()
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

    init(installer: WorkshopInstaller, onLibraryChanged: @escaping () -> Void) {
        self.installer = installer
        self.onLibraryChanged = onLibraryChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "창작마당"
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
        Self.current = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError("스토리보드를 쓰지 않는다") }

    // MARK: - 화면 구성

    private func makeContentView() -> NSView {
        let root = NSView()

        searchField.placeholderString = "검색"
        searchField.target = self
        searchField.action = #selector(reload)
        // 검색은 Enter로만 돈다. 글자마다 요청하면 스팀에 부담이고 결과가 튄다.
        searchField.sendsWholeSearchString = true

        for sort in WorkshopSort.allCases { sortPopup.addItem(withTitle: sort.label) }
        sortPopup.target = self
        sortPopup.action = #selector(reload)

        // 종류 필터. 목록은 이미 받아 왔으므로 다시 요청하지 않고 화면만 거른다.
        for title in Self.kindTitles { kindPopup.addItem(withTitle: title) }
        kindPopup.target = self
        kindPopup.action = #selector(refreshTable)

        hideInstalledCheckbox.state = .off
        hideInstalledCheckbox.target = self
        hideInstalledCheckbox.action = #selector(refreshTable)

        let refreshButton = NSButton(title: "새로고침", target: self, action: #selector(reload))

        prevButton.target = self
        prevButton.action = #selector(previousPage)
        nextButton.target = self
        nextButton.action = #selector(nextPage)
        pageLabel.alignment = .center
        pageLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let top = NSStackView(views: [
            searchField, sortPopup, kindPopup, hideInstalledCheckbox,
            prevButton, pageLabel, nextButton, refreshButton,
        ])
        top.orientation = .horizontal
        top.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

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

        let bottom = NSStackView(views: [
            NSTextField(labelWithString: "계정:"), accountField, loginButton,
            spinner, statusLabel, removeButton, downloadButton,
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

    private func loadPage() {
        pageLabel.stringValue = "\(page)"
        prevButton.isEnabled = page > 1
        loadGeneration += 1
        let generation = loadGeneration
        let sort = WorkshopSort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        let text = searchField.stringValue
        let requested = page
        setBusy(true, status: "목록을 읽는 중…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await client.listIDs(
                    sort: sort, searchText: text, page: requested)
                let fetched = try await client.details(ids: ids)
                // 늦게 도착한 옛 요청이 새 결과를 덮어쓰지 않게 한다.
                guard generation == self.loadGeneration else { return }
                self.items = fetched
                self.thumbnails.removeAll()
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
            } catch {
                guard generation == self.loadGeneration else { return }
                self.items = []
                self.refreshTable()
                self.setBusy(false, status: "목록을 읽지 못했다: \(Self.describe(error))")
            }
        }
    }

    /// 종류 필터의 표시 이름. 순서가 곧 팝업 순서다.
    static let kindTitles = ["모든 종류", "씬", "비디오", "웹"]

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

    /// 지금 고른 항목. 격자는 선택이 여러 개일 수 있으나 하나만 허용한다.
    private var selectedItem: WorkshopItem? {
        guard let index = collectionView.selectionIndexPaths.first?.item else { return nil }
        let list = visibleItems
        return index < list.count ? list[index] : nil
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
        guard let item = selectedItem else { return }
        do {
            if try installer.unlink(id: item.id) {
                onLibraryChanged()
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
        let item = selectedItem
        let installed = item.map { installer.isInstalled(id: $0.id) } ?? false
        downloadButton.isEnabled = item != nil && !isDownloading
        removeButton.isEnabled = installed && !isDownloading
        downloadButton.title = installed ? "다시 받기" : "받아서 추가"
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

    func configure(item: WorkshopItem, image: NSImage?, installed: Bool) {
        preview.image = image
        nameLabel.stringValue = item.title
        let megabytes = Double(item.sizeBytes) / 1_000_000
        detailLabel.stringValue = String(format: "%@ · %.1f MB%@",
                                      item.kind.rawValue, megabytes,
                                      installed ? " · 이미 있음" : "")
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
        -> Int { visibleItems.count }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(
            withIdentifier: WorkshopGridItem.identifier, for: indexPath)
        let list = visibleItems
        if let grid = cell as? WorkshopGridItem, indexPath.item < list.count {
            let item = list[indexPath.item]
            grid.configure(item: item, image: thumbnailImage(for: item.id),
                           installed: installer.isInstalled(id: item.id))
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
