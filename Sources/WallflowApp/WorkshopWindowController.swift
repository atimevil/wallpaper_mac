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

    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let sceneOnlyCheckbox = NSButton(checkboxWithTitle: "씬만 보기", target: nil, action: nil)
    private let accountField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "받아서 추가", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var items: [WorkshopItem] = []
    private var thumbnails: [String: NSImage] = [:]
    /// 진행 중인 목록 요청. 검색어를 빠르게 바꿀 때 옛 응답이 늦게 도착해
    /// 새 결과를 덮어쓰는 것을 막는다.
    private var loadGeneration = 0
    private var isDownloading = false

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

        sceneOnlyCheckbox.state = .off
        sceneOnlyCheckbox.target = self
        sceneOnlyCheckbox.action = #selector(refreshTable)

        let refreshButton = NSButton(title: "새로고침", target: self, action: #selector(reload))

        let top = NSStackView(views: [searchField, sortPopup, sceneOnlyCheckbox, refreshButton])
        top.orientation = .horizontal
        top.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableView.headerView = nil
        tableView.rowHeight = 68
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(download)
        tableView.target = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

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

        let bottom = NSStackView(views: [
            NSTextField(labelWithString: "계정:"), accountField,
            spinner, statusLabel, downloadButton,
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

    @objc private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let sort = WorkshopSort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        let text = searchField.stringValue
        setBusy(true, status: "목록을 읽는 중…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await client.listIDs(sort: sort, searchText: text)
                let fetched = try await client.details(ids: ids)
                // 늦게 도착한 옛 요청이 새 결과를 덮어쓰지 않게 한다.
                guard generation == self.loadGeneration else { return }
                self.items = fetched
                self.thumbnails.removeAll()
                self.refreshTable()
                self.setBusy(false, status: fetched.isEmpty ? "결과가 없다" : "\(fetched.count)개")
                self.loadThumbnails(generation: generation)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.items = []
                self.refreshTable()
                self.setBusy(false, status: "목록을 읽지 못했다: \(Self.describe(error))")
            }
        }
    }

    /// 화면에 쓰는 목록. 체크박스가 켜져 있으면 씬만 남긴다.
    private var visibleItems: [WorkshopItem] {
        sceneOnlyCheckbox.state == .on ? items.filter { $0.kind == .scene } : items
    }

    @objc private func refreshTable() {
        tableView.reloadData()
        updateDownloadButton()
    }

    private func loadThumbnails(generation: Int) {
        for item in items {
            guard let url = item.previewURL else { continue }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                guard let self, generation == self.loadGeneration else { return }
                self.thumbnails[item.id] = image
                // 보이는 줄만 다시 그린다. 전체 reload는 선택을 잃는다.
                if let row = self.visibleItems.firstIndex(where: { $0.id == item.id }) {
                    self.tableView.reloadData(
                        forRowIndexes: IndexSet(integer: row),
                        columnIndexes: IndexSet(integer: 0))
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
        let row = tableView.selectedRow
        let list = visibleItems
        guard row >= 0, row < list.count else { return }
        let item = list[row]

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
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try steam.download(workshopID: item.id, login: account)
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
    private func presentLoginHelp(account: String?) {
        let name = account?.isEmpty == false ? account! : "<계정이름>"
        present(
            title: "스팀 로그인이 필요하다",
            message: """
            터미널에서 아래를 한 번 실행해 로그인하세요. 비밀번호와 Steam Guard 코드를 \
            물어봅니다. 이 앱은 비밀번호를 저장하지도 다루지도 않습니다.

                steamcmd +login \(name)

            로그인이 끝나면 `quit`으로 나온 뒤 다시 받기를 누르세요.
            """)
    }

    // MARK: - 잡동사니

    private func setBusy(_ busy: Bool, status: String) {
        statusLabel.stringValue = status
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateDownloadButton()
    }

    private func updateDownloadButton() {
        let row = tableView.selectedRow
        let list = visibleItems
        let hasSelection = row >= 0 && row < list.count
        downloadButton.isEnabled = hasSelection && !isDownloading
        if hasSelection, installer.isInstalled(id: list[row].id) {
            downloadButton.title = "다시 받기"
        } else {
            downloadButton.title = "받아서 추가"
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

extension WorkshopWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let list = visibleItems
        guard row < list.count else { return nil }
        let item = list[row]

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.image = thumbnails[item.id]
        image.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let megabytes = Double(item.sizeBytes) / 1_000_000
        var detail = String(format: "%@ · %.1f MB", item.kind.rawValue, megabytes)
        if installer.isInstalled(id: item.id) { detail += " · 이미 있음" }
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDownloadButton()
    }
}
