import XCTest
@testable import WallflowKit

final class WorkshopClientTests: XCTestCase {
    /// 목록 HTML에서 의존하는 것은 `filedetails/?id=숫자` 하나뿐이다.
    /// 순서를 지키고 중복을 없애야 한다 — 한 아이템이 페이지에 여러 번 나온다.
    func testParsesIDsInOrderWithoutDuplicates() {
        let html = """
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111">x</a>
        <img src="/sharedfiles/filedetails/?id=111">
        <a href="/sharedfiles/filedetails/?id=222">y</a>
        <a href="/sharedfiles/filedetails/?id=333&searchtext=">z</a>
        """
        XCTAssertEqual(WorkshopClient.parseIDs(from: html), ["111", "222", "333"])
    }

    func testParsesEmptyPage() {
        XCTAssertEqual(WorkshopClient.parseIDs(from: "<html>결과 없음</html>"), [])
    }

    /// 응답이 이상해도 메모리가 터지면 안 된다.
    func testCapsIDCount() {
        let html = (0..<500).map { "filedetails/?id=\($0)" }.joined(separator: " ")
        XCTAssertEqual(WorkshopClient.parseIDs(from: html).count, WorkshopClient.maxIDsPerPage)
    }

    /// file_size가 문자열로 올 때와 수로 올 때가 둘 다 있다.
    func testParsesDetailsWithEitherSizeType() throws {
        let json = """
        {"response": {"resultcount": 2, "publishedfiledetails": [
          {"result": 1, "publishedfileid": "1", "title": "문자열 크기",
           "file_size": "1266514", "preview_url": "https://x/y.jpg",
           "tags": [{"tag": "Scene"}, {"tag": "Anime"}]},
          {"result": 1, "publishedfileid": "2", "title": "수 크기",
           "file_size": 42, "tags": [{"tag": "Video"}]}
        ]}}
        """
        let items = try WorkshopClient.parseDetails(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].sizeBytes, 1266514)
        XCTAssertEqual(items[0].kind, .scene)
        XCTAssertNotNil(items[0].previewURL)
        XCTAssertEqual(items[1].sizeBytes, 42)
        XCTAssertEqual(items[1].kind, .video)
        XCTAssertNil(items[1].previewURL)
    }

    /// 삭제됐거나 비공개인 아이템은 목록에 남기지 않는다.
    /// 남기면 사용자가 눌렀을 때 다운로드가 실패한다.
    func testDropsUnavailableItems() throws {
        let json = """
        {"response": {"publishedfiledetails": [
          {"result": 9, "publishedfileid": "1"},
          {"result": 1, "publishedfileid": "2", "title": "정상", "file_size": 1}
        ]}}
        """
        let items = try WorkshopClient.parseDetails(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["2"])
    }

    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try WorkshopClient.parseDetails(Data("쓰레기".utf8)))
        XCTAssertThrowsError(try WorkshopClient.parseDetails(Data("{}".utf8)))
    }

    /// 태그에 종류가 없으면 unsupported다. 목록에서 걸러낼 수 있어야 한다.
    func testKindFromTags() {
        func item(_ tags: [String]) -> WorkshopItem {
            WorkshopItem(id: "1", title: "t", sizeBytes: 0, previewURL: nil, tags: tags)
        }
        XCTAssertEqual(item(["Anime", "Scene"]).kind, .scene)
        XCTAssertEqual(item(["video"]).kind, .video)
        XCTAssertEqual(item(["Wallpaper"]).kind, .unsupported)
        XCTAssertEqual(item([]).kind, .unsupported)
    }
}

/// 목록 요청을 어떻게 조립하는지. 네트워크 없이 확인한다.
extension WorkshopClientTests {
    private func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
    }

    /// 인기 정렬만 기간을 달고 나간다.
    func testBrowseURLCarriesSortAndDays() {
        let week = query(WorkshopClient.browseURL(
            sort: .trendWeek, filter: WorkshopFilter(), searchText: "", page: 1))
        XCTAssertTrue(week.contains { $0 == ("browsesort", "trend") })
        XCTAssertTrue(week.contains { $0 == ("days", "7") })

        let rated = query(WorkshopClient.browseURL(
            sort: .topRated, filter: WorkshopFilter(), searchText: "", page: 1))
        XCTAssertTrue(rated.contains { $0 == ("browsesort", "toprated") })
        XCTAssertFalse(rated.contains { $0.0 == "days" }, "기간은 인기 정렬에만 붙는다")
    }

    /// 검색어가 있으면 정렬은 스팀이 관련도로 정한다. 그래도 태그는 함께 간다.
    func testBrowseURLKeepsTagsWhileSearching() {
        let items = query(WorkshopClient.browseURL(
            sort: .topRated, filter: WorkshopFilter(tags: ["Scene", "Anime"]),
            searchText: " minecraft ", page: 2))
        XCTAssertTrue(items.contains { $0 == ("browsesort", "textsearch") })
        XCTAssertTrue(items.contains { $0 == ("searchtext", "minecraft") })
        XCTAssertTrue(items.contains { $0 == ("requiredtags[]", "Scene") })
        XCTAssertTrue(items.contains { $0 == ("requiredtags[]", "Anime") })
        XCTAssertTrue(items.contains { $0 == ("p", "2") })
    }

    /// 빈 태그는 "제한 없음"이라 보내면 안 된다. 그대로 보내면 스팀이
    /// 아무것도 안 준다.
    func testFilterDropsEmptyAndDuplicateTags() {
        let filter = WorkshopFilter(tags: ["", "  ", "Scene", "Scene", " Anime "])
        XCTAssertEqual(filter.tags, ["Scene", "Anime"])
        XCTAssertFalse(filter.isEmpty)
        XCTAssertTrue(WorkshopFilter(tags: ["", " "]).isEmpty)
    }

    /// 고른 순서가 달라도 같은 조건이면 캐시 키가 같아야 한다.
    /// 안 그러면 같은 목록을 두 번 받는다.
    func testFilterKeyIsOrderIndependent() {
        XCTAssertEqual(WorkshopFilter(tags: ["Scene", "Anime"]).key,
                       WorkshopFilter(tags: ["Anime", "Scene"]).key)
    }

    /// 태그 목록의 첫 칸은 "제한 없음"이라 빈 태그여야 한다.
    /// 여기에 진짜 태그가 들어가면 기본 화면부터 걸러진 목록이 뜬다.
    func testTagChoicesStartWithNoRestriction() {
        for choices in [WorkshopTag.kinds, WorkshopTag.genres,
                        WorkshopTag.resolutions, WorkshopTag.ratings] {
            XCTAssertEqual(choices.first?.tag, "")
            XCTAssertTrue(choices.dropFirst().allSatisfy { !$0.tag.isEmpty })
        }
    }
}

extension WorkshopClientTests {
    /// 실제 스팀을 상대로 확인한다. 스크래핑은 상대가 바뀌면 조용히 깨지므로
    /// 합성 HTML만으로는 살아 있다는 증거가 되지 않는다.
    /// 네트워크가 필요하므로 WALLFLOW_LIVE_STEAM을 설정할 때만 돈다.
    func testLiveListingAndDetails() async throws {
        guard ProcessInfo.processInfo.environment["WALLFLOW_LIVE_STEAM"] != nil else {
            throw XCTSkip("WALLFLOW_LIVE_STEAM 미설정")
        }
        let client = WorkshopClient()
        let ids = try await client.listIDs(sort: .trendWeek)
        XCTAssertGreaterThanOrEqual(ids.count, 10, "목록에서 아이템 번호를 못 읽었다")

        let items = try await client.details(ids: ids)
        XCTAssertGreaterThanOrEqual(items.count, 10, "메타데이터를 못 읽었다")
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty }, "제목이 빈 항목이 있다")
        // 목록 순서를 지켜야 한다. 스팀 응답 순서에 기대면 인기순이 뒤섞인다.
        let returned = items.map(\.id)
        XCTAssertEqual(returned, ids.filter { returned.contains($0) }, "목록 순서가 지켜지지 않았다")
        // 씬이 하나도 없으면 종류 판정이 깨진 것이다.
        XCTAssertTrue(items.contains { $0.kind != .unsupported }, "종류를 하나도 못 읽었다")
    }

    /// 정렬 값이 실제로 스팀에 먹힌다.
    ///
    /// **모르는 `browsesort`를 주면 스팀은 오류를 내지 않고 기본 정렬로 되돌린다.**
    /// 그래서 값을 지어내면 화면상 아무 일도 없고 아무도 눈치채지 못한다 —
    /// 결과가 서로 다른지를 봐야 한다.
    func testLiveEachSortGivesDifferentResults() async throws {
        guard ProcessInfo.processInfo.environment["WALLFLOW_LIVE_STEAM"] != nil else {
            throw XCTSkip("WALLFLOW_LIVE_STEAM 미설정")
        }
        let client = WorkshopClient()
        var heads: [WorkshopSort: [String]] = [:]
        for sort in WorkshopSort.allCases {
            let ids = try await client.listIDs(sort: sort)
            XCTAssertGreaterThanOrEqual(ids.count, 10, "\(sort.label)에서 목록이 비었다")
            heads[sort] = Array(ids.prefix(5))
        }
        // 기간이 다른 인기 정렬끼리도 달라야 한다. `days`를 안 보내면 전부 같아진다.
        XCTAssertNotEqual(heads[.trendToday], heads[.trendWeek], "인기 기간이 안 먹힌다")
        XCTAssertNotEqual(heads[.trendWeek], heads[.trendYear], "인기 기간이 안 먹힌다")
        XCTAssertNotEqual(heads[.topRated], heads[.trendWeek], "최고 평점이 안 먹힌다")
        XCTAssertNotEqual(heads[.mostRecent], heads[.trendWeek], "가장 최근이 안 먹힌다")
        XCTAssertNotEqual(heads[.lastUpdated], heads[.trendWeek], "최근 업데이트가 안 먹힌다")
        XCTAssertNotEqual(heads[.mostSubscribed], heads[.trendWeek], "최다 구독이 안 먹힌다")
    }

    /// 태그 조건이 **모든 페이지에** 걸린다. 받아 온 페이지만 거르면
    /// "웹 배경화면"을 골라도 그 페이지에 든 두어 개만 남는다.
    func testLiveTagFilterAppliesServerSide() async throws {
        guard ProcessInfo.processInfo.environment["WALLFLOW_LIVE_STEAM"] != nil else {
            throw XCTSkip("WALLFLOW_LIVE_STEAM 미설정")
        }
        let client = WorkshopClient()
        let ids = try await client.listIDs(filter: WorkshopFilter(tags: ["Web"]))
        XCTAssertGreaterThanOrEqual(ids.count, 10, "조건을 걸었더니 목록이 비었다")
        let items = try await client.details(ids: ids)
        XCTAssertFalse(items.isEmpty)
        // 한 페이지가 통째로 웹이어야 한다. 화면에서 거른 것이라면 그럴 수 없다.
        XCTAssertTrue(items.allSatisfy { $0.kind == .web },
                      "웹이 아닌 것이 섞였다: \(items.filter { $0.kind != .web }.map(\.title))")

        // 두 태그를 함께 걸면 둘 다 가진 것만 남는다.
        let both = try await client.details(
            ids: try await client.listIDs(filter: WorkshopFilter(tags: ["Scene", "Anime"])))
        XCTAssertFalse(both.isEmpty)
        XCTAssertTrue(both.allSatisfy { $0.kind == .scene }, "씬이 아닌 것이 섞였다")
        XCTAssertTrue(both.allSatisfy { $0.tags.contains("Anime") }, "아니메가 아닌 것이 섞였다")
    }

    /// 검색이 실제로 다른 결과를 낸다.
    func testLiveSearchNarrowsResults() async throws {
        guard ProcessInfo.processInfo.environment["WALLFLOW_LIVE_STEAM"] != nil else {
            throw XCTSkip("WALLFLOW_LIVE_STEAM 미설정")
        }
        let client = WorkshopClient()
        let trending = try await client.listIDs(sort: .trendWeek)
        let searched = try await client.listIDs(searchText: "minecraft")
        XCTAssertFalse(searched.isEmpty, "검색 결과가 비었다")
        XCTAssertNotEqual(Set(trending), Set(searched), "검색어가 무시되고 있다")
    }
}
