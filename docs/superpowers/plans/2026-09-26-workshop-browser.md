# 창작마당 창 WE 브라우저화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 같은 웨이브의 작업은 각자 워크트리에서 병렬로 돈다.

**Goal:** 창작마당 창을 WE 창작마당 브라우저처럼 세 칸(체크박스 필터 사이드바 · 호버 GIF·무한 스크롤 격자 · 상세/속성 패널)으로 바꾸고, 더블클릭으로 받기/적용한다.

**Architecture:** 해석·필터·병합 같은 판단은 WallflowKit 순수 함수(테스트), 화면은 WallflowApp AppKit. 기존 `WorkshopWindowController`의 받기/지우기/적용/로그인 흐름은 그대로 쓰고 화면만 세 칸으로 다시 짠다. 속성 편집 코드는 설정 창에서 떼어 두 곳이 같이 쓴다.

**Tech Stack:** Swift 6 / SwiftPM, AppKit(NSSplitView, NSCollectionView, NSImageView 애니메이션), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-26-workshop-browser-design.md`

## Global Constraints

- `WallflowKit`은 AppKit·Metal·AVFoundation·WebKit을 import하지 않는다. 판단은 Kit 순수 함수로 두고 테스트한다.
- 전체 테스트: `WALLFLOW_TEST_SCENES="$HOME/Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960" WALLFLOW_TEST_ASSETS="$HOME/Library/Application Support/Wallflow/Assets" swift test` — 기준 main에서 실패 0. 새로 빌드한 경고 0(`rm -rf .build && swift build`).
- Steam 자격 증명을 다루지 않는다. 목록·정보는 로그인 없는 공개 페이지와 `GetPublishedFileDetails`만.
- 커밋 메시지는 한국어 "…한다" 한 문장, `Co-Authored-By`·`Claude-Session` 줄 금지. 주석은 한국어로 "왜".
- 화면 확인은 공용 촬영기 대신 메인 세션이 한다(창작마당 창은 배경화면 창이 아니다). 서브에이전트는 앱을 띄우지 않는다.

## Review Focus

1. **무한 스크롤 중복·경합** — 스크롤을 빨리 내리거나 필터를 바꾸는 사이 옛 페이지 응답이 도착해도 섞이지 않고, 같은 항목이 두 번 나오지 않는다(T1 병합 테스트, T4 세대 번호).
2. **OR 필터의 빈 결과** — 종류를 둘 이상 고르면 클라이언트에서 거르므로 한 페이지가 통째로 비어도 다음 페이지를 계속 받아 화면을 채운다(T2 판정 테스트, T4 "빈 페이지면 한 번 더").
3. **상세 페이지 모양 변화** — 평점·작성자를 못 뽑아도 나머지 패널은 뜬다(T1 빈 HTML 테스트).
4. **호버 GIF 부하** — 큰 GIF를 여럿 지나가도 움직이는 칸은 하나뿐이고 메모리 캐시에 상한이 있다(T4).
5. **속성 편집 즉시 반영** — 설치됨 탭에서 바꾼 값이 설정 창과 같은 저장소에 저장되고 켜진 배경화면에 바로 반영된다(T3·T6).

---

## 웨이브 1 (병렬 3개)

### Task 1: 창작마당 정보 확장·상세 페이지 해석 (Kit)

**Files:**
- Modify: `Sources/WallflowKit/Workshop/WorkshopClient.swift` (`WorkshopItem` 필드, `parseDetails`)
- Create: `Sources/WallflowKit/Workshop/WorkshopDetailsPage.swift`
- Test: `Tests/WallflowKitTests/WorkshopClientTests.swift`, `Tests/WallflowKitTests/WorkshopDetailsPageTests.swift`

**Interfaces — Produces:**
- `WorkshopItem`에 `description: String`, `createdAt: Date?`, `updatedAt: Date?`, `subscriptions: Int`, `favorites: Int`, `views: Int`, `creatorID: String?` (모두 기본값 있는 init 인자 — 기존 호출부는 그대로 컴파일)
- `public struct WorkshopDetailsPage: Equatable, Sendable { rating: Double?  /* 0…5, 0.5 단위 */; ratingCount: Int?; author: String? ; static func parse(html: String) -> WorkshopDetailsPage }`
- `WorkshopClient.detailsPage(id: String) async throws -> WorkshopDetailsPage` (User-Agent `Mozilla/5.0`, 20초)
- `public enum WorkshopText { static func plain(fromBBCode: String) -> String }` — `[b]` `[i]` `[u]` `[url=…]x[/url]`→x, `[h1]`…, `[list][*]`→"• ", `[img]…[/img]` 제거, 나머지 태그 제거
- `public enum WorkshopPaging { static func merge(_ existing: [WorkshopItem], _ page: [WorkshopItem]) -> [WorkshopItem] }` — 순서 유지, id 중복 제거

- [ ] **Step 1: 실패하는 테스트**

```swift
// WorkshopDetailsPageTests.swift
import XCTest
@testable import WallflowKit

final class WorkshopDetailsPageTests: XCTestCase {
    // 실물 상세 페이지(3803492669)에서 잘라 온 조각.
    let real = """
    <div class="ratingSection">
        <div class="fileRatingDetails"><img src="https://community.fastly.steamstatic.com/public/images/sharedfiles/4-star_large.png?v=2" /></div>
        <div class="numRatings">26 ratings</div>				</div>
    <div class="friendBlockContent">
        s1lent<br>
        <span class="friendSmallText">
    Offline
        </span>
    </div>
    """
    func testParsesRatingCountAndAuthor() {
        let page = WorkshopDetailsPage.parse(html: real)
        XCTAssertEqual(page.rating, 4)
        XCTAssertEqual(page.ratingCount, 26)
        XCTAssertEqual(page.author, "s1lent")
    }
    func testHalfStarAndThousands() {
        let html = #"<div class="fileRatingDetails"><img src="x/3-star_large.png" /></div><div class="numRatings">1,204 ratings</div>"#
        XCTAssertEqual(WorkshopDetailsPage.parse(html: html).ratingCount, 1204)
        XCTAssertEqual(WorkshopDetailsPage.parse(html: html).rating, 3)
    }
    func testNotEnoughRatings() {
        let html = #"<div class="fileRatingDetails"><img src="x/not-yet_large.png" /></div><div class="numRatings">Not enough ratings</div>"#
        let page = WorkshopDetailsPage.parse(html: html)
        XCTAssertNil(page.rating)
        XCTAssertNil(page.ratingCount)
    }
    func testGarbageYieldsEmptyNotCrash() {
        XCTAssertEqual(WorkshopDetailsPage.parse(html: "<html></html>"),
                       WorkshopDetailsPage(rating: nil, ratingCount: nil, author: nil))
    }
    func testBBCodeToPlain() {
        XCTAssertEqual(WorkshopText.plain(fromBBCode: "[h1]Hi[/h1]\n[b]bold[/b] [url=https://x]link[/url][list][*]a[*]b[/list][img]p.png[/img]"),
                       "Hi\nbold link\n• a\n• b")
    }
    func testMergeDropsDuplicatesKeepsOrder() {
        func item(_ id: String) -> WorkshopItem { WorkshopItem(id: id, title: id, sizeBytes: 0, previewURL: nil, tags: []) }
        XCTAssertEqual(WorkshopPaging.merge([item("1"), item("2")], [item("2"), item("3")]).map(\.id), ["1", "2", "3"])
    }
}
```

`WorkshopClientTests`에 `parseDetails` 확장 필드 테스트를 더한다(JSON에 `description`, `time_created: 1700000000`, `time_updated`, `subscriptions`, `favorited`, `views`, `creator: "7656…"`를 넣고 값 확인; `subscriptions`가 문자열로 와도 읽힘).

- [ ] **Step 2:** `swift test --filter WorkshopDetailsPageTests` → 컴파일 실패(타입 없음) 확인.
- [ ] **Step 3: 구현** — 정규식: 평점 `(\d)(?:_half)?-star_large`(half면 +0.5), 개수 `numRatings">([\d,]+) ratings`, 작성자 `friendBlockContent">\s*([^<]+?)\s*<br`. `parseDetails`는 숫자가 Int·String 어느 쪽이어도 읽는 헬퍼로 새 필드를 채운다. `detailsPage(id:)`는 `https://steamcommunity.com/sharedfiles/filedetails/?id=<id>`를 받아 `parse`. id는 숫자만 허용(아니면 빈 결과).
- [ ] **Step 4:** 필터 테스트 통과, 전체 스위트 통과, 경고 0.
- [ ] **Step 5: 커밋** `창작마당 항목의 설명·날짜·구독 수와 상세 페이지 평점·작성자를 읽는다`

### Task 2: 사이드바 필터 모델과 라이브러리 태그 (Kit)

**Files:**
- Create: `Sources/WallflowKit/Workshop/WorkshopFilterState.swift`
- Modify: `Sources/WallflowKit/WallpaperItem.swift` (`tags: [String]` — project.json `tags`)
- Test: `Tests/WallflowKitTests/WorkshopFilterStateTests.swift`

**Interfaces — Produces:**
```swift
public enum WorkshopFilterSection: String, CaseIterable, Sendable {
    case kind, rating, resolution, genre, flag
    /// 같은 섹션에서 여럿 고르면 "그중 하나"인지.
    public var isAnyOf: Bool { self == .kind || self == .rating || self == .resolution }
    public var choices: [WorkshopTag.Choice] // WorkshopTag.kinds/ratings/resolutions/genres/flags에서 빈 태그("모든…") 뺀 것
}
public struct WorkshopFilterState: Equatable, Sendable {
    public var selected: [WorkshopFilterSection: Set<String>]  // 태그 값
    public var hideInstalled: Bool
    public init()                                   // 기본: rating = ["Everyone"]
    public mutating func toggle(_ tag: String, in section: WorkshopFilterSection)
    public mutating func reset()                    // 기본값으로
    /// Steam 요청에 실을 조건. OR 섹션은 하나만 골랐을 때만 싣는다.
    public var requestFilter: WorkshopFilter
    /// 받아 온(또는 설치된) 항목이 조건에 맞는지. OR 섹션 둘 이상은 여기서 거른다.
    public func matches(tags: [String]) -> Bool
    public var key: String                          // 캐시 키(정렬 안정)
}
```
- `WallpaperItem.tags` (없으면 `[]`), 기존 init 호출부는 기본값으로 유지.

- [ ] **Step 1: 실패하는 테스트**

```swift
final class WorkshopFilterStateTests: XCTestCase {
    func testDefaultIsEveryoneOnly() {
        let s = WorkshopFilterState()
        XCTAssertEqual(s.requestFilter.tags, ["Everyone"])
    }
    func testSingleKindGoesToRequest() {
        var s = WorkshopFilterState(); s.toggle("Scene", in: .kind)
        XCTAssertEqual(Set(s.requestFilter.tags), ["Everyone", "Scene"])
        XCTAssertTrue(s.matches(tags: ["Scene", "Everyone"]))
    }
    func testTwoKindsAreClientSideOr() {
        var s = WorkshopFilterState(); s.toggle("Scene", in: .kind); s.toggle("Video", in: .kind)
        XCTAssertFalse(s.requestFilter.tags.contains("Scene"))
        XCTAssertFalse(s.requestFilter.tags.contains("Video"))
        XCTAssertTrue(s.matches(tags: ["Video", "Everyone"]))
        XCTAssertFalse(s.matches(tags: ["Web", "Everyone"]))
    }
    func testGenresAreAnd() {
        var s = WorkshopFilterState(); s.toggle("Anime", in: .genre); s.toggle("Girls", in: .genre)
        XCTAssertTrue(Set(s.requestFilter.tags).isSuperset(of: ["Anime", "Girls"]))
        XCTAssertTrue(s.matches(tags: ["Anime", "Girls", "Everyone"]))
        XCTAssertFalse(s.matches(tags: ["Anime", "Everyone"]))
    }
    func testMatchingIsCaseInsensitive() {
        var s = WorkshopFilterState(); s.toggle("Audio responsive", in: .flag)
        XCTAssertTrue(s.matches(tags: ["audio responsive", "everyone"]))
    }
    func testToggleTwiceRemovesAndResetRestoresDefault() {
        var s = WorkshopFilterState(); s.toggle("Anime", in: .genre); s.toggle("Anime", in: .genre)
        XCTAssertEqual(s, WorkshopFilterState())
        s.toggle("Mature", in: .rating); s.reset()
        XCTAssertEqual(s, WorkshopFilterState())
    }
    func testKeyIsOrderIndependent() {
        var a = WorkshopFilterState(); a.toggle("Anime", in: .genre); a.toggle("Girls", in: .genre)
        var b = WorkshopFilterState(); b.toggle("Girls", in: .genre); b.toggle("Anime", in: .genre)
        XCTAssertEqual(a.key, b.key)
    }
}
```
라이브러리 태그: 임시 폴더에 `project.json`(`"tags": ["Anime", "Relaxing"]`)을 만들어 `WallpaperItem` 로드 결과 `tags` 확인(기존 WallpaperItem 테스트 방식을 따른다).

- [ ] **Step 2:** 실패 확인. **Step 3:** 구현(등급 섹션이 비면 요청에 등급 태그 없음 = 제한 없음). **Step 4:** 전체 통과·경고 0.
- [ ] **Step 5: 커밋** `창작마당 사이드바의 섹션별 여러 선택 필터를 판정한다`

### Task 3: 속성 편집기 떼어내기 (App)

**Files:**
- Create: `Sources/WallflowApp/PropertyEditorView.swift`
- Modify: `Sources/WallflowApp/SettingsWindowController.swift` (속성 탭이 새 뷰를 쓰게: `makePropertiesTab`, `makeRow`, `controlChanged`, `applyConditions`, `resetAll`, `persistAndReload` 이동)

**Interfaces — Produces:**
```swift
@MainActor final class PropertyEditorView: NSView {
    init(store: UserPropertyStore, onChanged: @escaping () -> Void)
    /// 이 배경화면의 속성을 보여 준다. nil이면 "속성이 없다" 안내.
    func show(item: WallpaperItem?)
}
```
- 저장·조건부 표시·초기화·슬라이더 수치 표시·오류 알림은 지금 설정 창 동작 그대로 옮긴다(동작 변화 없음). 설정 창은 이 뷰를 속성 탭에 넣고, 기존 `reloadProperties()`가 `editor.show(item:)`를 부른다.
- [ ] **Step 1:** 옮기기 전후 동작이 같음을 확인할 Kit 테스트가 이미 있는지 확인(`UserProperty` 테스트). App 테스트 타깃은 없으므로 이 작업은 빌드·기존 스위트·코드 검토로 확인한다.
- [ ] **Step 2:** 옮긴다. `SettingsWindowController`는 편집기를 쓰는 얇은 껍데기가 된다.
- [ ] **Step 3:** 전체 통과·경고 0.
- [ ] **Step 4: 커밋** `속성 편집기를 설정 창에서 떼어 다른 창도 쓰게 한다`

## 웨이브 2 (T1·T2 병합 후, 병렬 2개)

### Task 4: 세 칸 창·사이드바·무한 스크롤 격자·호버 GIF (App)

**Files:**
- Modify: `Sources/WallflowApp/WorkshopWindowController.swift`
- Create: `Sources/WallflowApp/WorkshopSidebarView.swift`, `Sources/WallflowApp/WorkshopGridItem.swift`(기존 `WorkshopGridItem`·`PreviewView`를 여기로 옮기고 확장)

**Interfaces — Consumes:** `WorkshopFilterState`, `WorkshopFilterSection`(T2), `WorkshopPaging.merge`(T1), `WallpaperItem.tags`(T2).
**Produces:** 창 오른쪽 칸에 둘 컨테이너 `detailContainer: NSView`와 선택 알림 `private func selectionDidChange()`(T6가 채움). 더블클릭 훅 `private func activateSelected()`(T6가 채움 — 지금은 창작마당=받기, 설치됨=적용을 기존 메서드로 호출).

- [ ] 창: 1280×800, 최소 980×600, `NSSplitView`(사이드바 220 · 격자 · 오른쪽 340, 사이드바 접기). 위쪽 세그먼트는 `설치됨 / 창작마당` 둘(기존 `search` 탭은 창작마당의 검색창으로 합친다), 계정·로그인 버튼은 창작마당 탭 위쪽 줄 오른쪽.
- [ ] 사이드바: `WorkshopFilterSection.allCases` 순서로 제목+체크박스 목록(스크롤), 맨 아래 `받은 것 숨기기`, `초기화`. 바뀌면 `filterState`를 갱신하고 목록을 처음부터 다시 받는다(세대 번호 증가). 설치됨 탭에서는 같은 상태로 로컬 목록을 `matches(tags:)`로 거른다.
- [ ] 격자 위 줄: 검색창, 정렬 팝업(기존 8종), 칸 크기 슬라이더(160~320, `UserDefaults` `wallflow.workshop.cellSize`에 기억).
- [ ] 무한 스크롤: 스크롤 뷰의 bounds 변화를 관찰해 끝에서 두 줄 앞이면 다음 페이지 요청(진행 중이면 무시). 응답은 세대 번호가 같을 때만 `WorkshopPaging.merge`로 붙인다. 클라이언트 필터 뒤 새로 붙은 칸이 0이면 한 번 더 다음 페이지를 요청(최대 연속 3회). 끝(빈 ID 목록)이면 멈춤. 이전/다음 버튼·페이지 번호 제거.
- [ ] 칸: 정사각 미리보기 + 제목 한 줄. 받은 항목 체크 배지, 받는 중 진행 막대(기존 진행 콜백 연결). 이미지 캐시는 `NSCache` 개수 상한 600.
- [ ] 호버 GIF: `NSTrackingArea`로 들어오면 그 칸의 `NSImageView.animates = true`(GIF 데이터로 만든 `NSImage`), 나가면 false. 한 번에 한 칸만.
- [ ] 더블클릭: `NSCollectionView`에 `NSClickGestureRecognizer(numberOfClicksRequired: 2)` → `activateSelected()`.
- [ ] 전체 통과·경고 0. 커밋 `창작마당 창을 필터 사이드바와 끝없이 이어지는 격자로 다시 짠다`

### Task 5: 상세 패널 뷰 (App, 독립 파일)

**Files:**
- Create: `Sources/WallflowApp/WorkshopDetailPanel.swift`

**Interfaces — Consumes:** `WorkshopItem` 확장 필드, `WorkshopDetailsPage`, `WorkshopText.plain`(T1); `PropertyEditorView`(T3).
**Produces:**
```swift
@MainActor final class WorkshopDetailPanel: NSView {
    var onPrimary: (() -> Void)?     // 받기 / 적용
    var onRemove: (() -> Void)?      // 설치됨: 지우기
    init(editor: PropertyEditorView)
    func showWorkshop(item: WorkshopItem, preview: NSImage?, page: WorkshopDetailsPage?, installed: Bool, progress: Double?)
    func showInstalled(item: WallpaperItem, preview: NSImage?)
    func showEmpty()
}
```
- [ ] 레이아웃(세로 스크롤): 큰 미리보기(16:9 비율 칸, `animates = true`), 제목(굵게, 여러 줄), 작성자, 별 5개(채움/반/빈 SF Symbols `star.fill`/`star.leadinghalf.filled`/`star`)+평가 수, 구독자·크기(`ByteCountFormatter`)·올린 날·고친 날(한국어 날짜), 태그 칩(작은 둥근 라벨, 줄바꿈), 설명(평문, 선택 가능한 `NSTextView` 읽기 전용), 버튼 줄. 창작마당: 받기(받은 것이면 "적용", 진행 중이면 진행 막대+비활성), "Steam에서 열기"(`NSWorkspace.open`). 설치됨: 적용·지우기, 그 아래 `PropertyEditorView`.
- [ ] 값이 없으면 그 줄만 숨긴다(평점 nil 등).
- [ ] 빌드·전체 통과·경고 0. 커밋 `창작마당 항목과 설치된 배경화면의 상세 패널을 만든다`

## 웨이브 3

### Task 6: 상세 패널 연결·상세 페이지 지연 로드·더블클릭 (App)

**Files:** Modify `Sources/WallflowApp/WorkshopWindowController.swift`, `Sources/WallflowApp/AppCoordinator.swift`(속성 변경 즉시 반영 연결이 필요하면)

- [ ] `detailContainer`에 `WorkshopDetailPanel` 배치. 선택이 바뀌면 창작마당: 패널 표시 후 `client.detailsPage(id:)`를 백그라운드로 받아(메모리 캐시) 같은 항목이 아직 선택돼 있으면 갱신. 설치됨: `showInstalled`, 편집기는 해당 배경화면.
- [ ] `onPrimary`/`onRemove`/더블클릭 → 기존 받기·적용·지우기 흐름. 창작마당에서 이미 받은 항목의 더블클릭·버튼은 적용.
- [ ] 속성 변경은 설정 창과 같은 `onPropertiesChanged` 경로로 켜진 배경화면에 즉시 반영.
- [ ] 전체 통과·경고 0. 커밋 `상세 패널을 창작마당 창에 붙이고 더블클릭으로 받거나 적용한다`

## Task 7: 실물 확인 (메인 세션)
- [ ] 앱을 띄워 창작마당 창: 필터 여러 개(종류 둘=클라이언트 OR, 장르 둘=AND), 스크롤로 3페이지 이상, 호버 GIF, 상세 패널 평점·작성자, 더블클릭 받기(작은 항목), 설치됨 탭 더블클릭 적용, 속성 바꾸기 즉시 반영, 창 크기 줄이기. 사용자 배경화면·설정 복원.
