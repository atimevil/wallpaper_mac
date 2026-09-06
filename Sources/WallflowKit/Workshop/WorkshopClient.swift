import Foundation

/// 창작마당 아이템 하나의 요약.
public struct WorkshopItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sizeBytes: Int
    public let previewURL: URL?
    public let tags: [String]

    /// 태그에서 읽은 종류. Wallpaper Engine이 `Scene`/`Video`/`Web`/`Application`을 붙인다.
    public var kind: WallpaperType {
        for tag in tags {
            switch tag.lowercased() {
            case "scene": return .scene
            case "video": return .video
            case "web": return .web
            default: continue
            }
        }
        return .unsupported
    }

    public init(id: String, title: String, sizeBytes: Int, previewURL: URL?, tags: [String]) {
        self.id = id
        self.title = title
        self.sizeBytes = sizeBytes
        self.previewURL = previewURL
        self.tags = tags
    }
}

/// 창작마당 목록의 정렬. 실물 Wallpaper Engine이 주는 것과 같은 여덟 가지다.
///
/// 스팀은 정렬을 `browsesort` 하나로 받고, **인기만 기간을 따로 받는다**
/// (`days=1/7/30/365`). 기간을 안 주면 일주일이 기본이다. 모르는 값을 주면
/// 스팀은 오류를 내지 않고 조용히 기본 정렬로 되돌린다 — 그래서 값을 지어내면
/// 사용자는 정렬이 바뀌지 않는 이유를 알 수 없다. 여기 있는 값은 전부
/// 실제로 요청해 결과가 달라지는 것을 확인한 것이다.
public enum WorkshopSort: String, Sendable, CaseIterable {
    /// 맨 앞이 화면의 기본값이다. 스팀의 기본도 일주일 인기다.
    case trendWeek
    case trendToday
    case trendMonth
    case trendYear
    case topRated
    case mostRecent
    case lastUpdated
    case mostSubscribed

    /// 스팀이 받는 `browsesort` 값.
    public var browseSort: String {
        switch self {
        case .trendToday, .trendWeek, .trendMonth, .trendYear: return "trend"
        case .topRated: return "toprated"
        case .mostRecent: return "mostrecent"
        case .lastUpdated: return "lastupdated"
        case .mostSubscribed: return "totaluniquesubscribers"
        }
    }

    /// 인기 정렬에만 딸리는 기간(일). 다른 정렬에는 붙이지 않는다.
    public var days: Int? {
        switch self {
        case .trendToday: return 1
        case .trendWeek: return 7
        case .trendMonth: return 30
        case .trendYear: return 365
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .trendToday: return "인기(오늘)"
        case .trendWeek: return "인기(이번 주)"
        case .trendMonth: return "인기(이번 달)"
        case .trendYear: return "인기(올해)"
        case .topRated: return "최고 평점"
        case .mostRecent: return "가장 최근"
        case .lastUpdated: return "최근 업데이트"
        case .mostSubscribed: return "최다 구독"
        }
    }
}

/// 창작마당이 붙이는 태그. 스팀에 `requiredtags[]`로 넘기면 **모든 페이지에**
/// 걸린다 — 받아 온 페이지만 거르면 "웹 배경화면"을 골라도 그 페이지에 든
/// 두어 개만 남는다.
///
/// 값은 실물 아이템 193개의 태그를 세어 뽑았다. 태그 이름은 스팀이 정한
/// 영문 그대로여야 한다(`Audio responsive`처럼 대소문자까지).
public enum WorkshopTag {
    /// 이름표와 태그의 짝. 화면에는 우리말, 요청에는 영문이 간다.
    public typealias Choice = (label: String, tag: String)

    public static let kinds: [Choice] = [
        ("모든 종류", ""), ("씬", "Scene"), ("비디오", "Video"), ("웹", "Web"),
    ]

    public static let genres: [Choice] = [
        ("모든 태그", ""), ("아니메", "Anime"), ("소녀", "Girls"), ("남자", "Guys"),
        ("경치", "Landscape"), ("자연", "Nature"), ("게임", "Game"), ("추상적", "Abstract"),
        ("공상과학", "Sci-Fi"), ("판타지", "Fantasy"), ("사이버펑크", "Cyberpunk"),
        ("카툰", "Cartoon"), ("동물", "Animal"), ("음악", "Music"), ("픽셀아트", "Pixel art"),
        ("레트로", "Retro"), ("중세", "Medieval"), ("밈", "Memes"), ("MMD", "MMD"),
        ("탈것", "Vehicle"), ("기술", "Technology"), ("3D", "3D"), ("CGI", "CGI"),
        ("릴렉싱", "Relaxing"),
    ]

    public static let resolutions: [Choice] = [
        ("모든 해상도", ""), ("1920 x 1080", "1920 x 1080"), ("2560 x 1440", "2560 x 1440"),
        ("3840 x 2160", "3840 x 2160"), ("울트라와이드 3440 x 1440", "Ultrawide 3440 x 1440"),
        ("세로 2160 x 3840", "Portrait 2160 x 3840"), ("듀얼 3840 x 1080", "Dual 3840 x 1080"),
        ("해상도 가변", "Dynamic resolution"),
    ]

    public static let ratings: [Choice] = [
        ("모든 등급", ""), ("전체 이용가", "Everyone"),
        ("선정성 있음", "Questionable"), ("성인", "Mature"),
    ]

    /// 켜고 끄는 특성들. 여러 개를 함께 걸 수 있다.
    public static let flags: [Choice] = [
        ("승인됨", "Approved"), ("오디오 응답성", "Audio responsive"),
        ("커스텀 가능", "Customizable"), ("Media Integration", "Media Integration"),
    ]
}

/// 목록에 거는 조건. 빈 태그는 "제한 없음"이라 빼고 보낸다.
public struct WorkshopFilter: Sendable, Equatable {
    public var tags: [String]

    /// 한 번에 걸 수 있는 태그 수. 스팀이 거절하지는 않지만 URL이 끝없이
    /// 길어질 이유도 없다.
    public static let maxTags = 8

    public init(tags: [String] = []) {
        // 빈 것과 중복을 걷어낸다. 같은 태그를 두 번 보내도 결과는 같지만,
        // 캐시 키가 달라져 같은 목록을 두 번 받게 된다.
        var seen = Set<String>()
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.maxTags)
            .map { $0 }
    }

    public var isEmpty: Bool { tags.isEmpty }

    /// 캐시 키에 쓰는 안정된 표현. 고른 순서가 달라도 같은 조건이면 같아야 한다.
    public var key: String { tags.sorted().joined(separator: ",") }

    public var queryItems: [URLQueryItem] {
        tags.map { URLQueryItem(name: "requiredtags[]", value: $0) }
    }
}

public enum WorkshopError: Error, Equatable {
    case badResponse(Int)
    case malformedPayload
}

/// 스팀 창작마당을 읽는다. 다운로드는 `SteamCmdClient`가 한다.
///
/// **목록은 HTML에서 아이템 번호만 긁는다.** 제목·크기·미리보기는 공식 API로 따로
/// 가져온다. 그래야 스팀이 페이지 모양을 바꿔도 깨질 곳이 `filedetails/?id=숫자`
/// 하나로 좁혀진다. 페이지 전체를 파싱하면 클래스 이름 하나 바뀔 때마다 무너진다.
///
/// API 키는 필요 없다. `GetPublishedFileDetails`는 공개 엔드포인트다.
public struct WorkshopClient: Sendable {
    /// 한 페이지에 받아올 개수. 스팀 기본값과 같다.
    public static let pageSize = 30

    /// 목록 한 번에 받아들일 최대 아이템 수. 응답이 이상해도 메모리가 터지지 않게 한다.
    static let maxIDsPerPage = 100

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 창작마당 목록에서 아이템 번호를 읽는다.
    public func listIDs(
        sort: WorkshopSort = .trendWeek, filter: WorkshopFilter = WorkshopFilter(),
        searchText: String = "", page: Int = 1
    ) async throws -> [String] {
        let url = Self.browseURL(sort: sort, filter: filter, searchText: searchText, page: page)
        var request = URLRequest(url: url)
        // 기본 User-Agent로는 스팀이 다른 페이지를 준다.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WorkshopError.badResponse(http.statusCode)
        }
        return Self.parseIDs(from: String(decoding: data, as: UTF8.self))
    }

    /// 목록 요청의 주소. 조립을 따로 떼어 두어야 네트워크 없이 확인할 수 있다.
    static func browseURL(
        sort: WorkshopSort, filter: WorkshopFilter, searchText: String, page: Int
    ) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var query = [
            URLQueryItem(name: "appid", value: SteamCmdClient.wallpaperEngineAppID),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "numperpage", value: "\(Self.pageSize)"),
            URLQueryItem(name: "p", value: "\(max(1, page))"),
        ]
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            query.append(URLQueryItem(name: "browsesort", value: sort.browseSort))
            // 기간은 인기 정렬에만 붙는다. 다른 정렬에 붙이면 무시되지만,
            // 안 보내는 편이 요청을 읽기 쉽다.
            if let days = sort.days {
                query.append(URLQueryItem(name: "days", value: "\(days)"))
            }
        } else {
            // 검색어가 있으면 정렬은 스팀이 관련도로 정한다.
            query.append(URLQueryItem(name: "browsesort", value: "textsearch"))
            query.append(URLQueryItem(name: "searchtext", value: trimmed))
        }
        // 태그는 검색과 함께 걸린다 — 검색어로 좁힌 뒤 종류로 또 좁힐 수 있다.
        query.append(contentsOf: filter.queryItems)
        components.queryItems = query
        return components.url!
    }

    /// 목록 HTML에서 아이템 번호만 뽑는다. 순서를 지키고 중복을 없앤다.
    static func parseIDs(from html: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        // `filedetails/?id=숫자`. 이 패턴만 의존한다.
        let pattern = try! NSRegularExpression(pattern: #"filedetails/\?id=(\d+)"#)
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let id = String(html[r])
            guard seen.insert(id).inserted else { continue }
            ordered.append(id)
            if ordered.count >= maxIDsPerPage { break }
        }
        return ordered
    }

    /// 아이템 번호들의 제목·크기·미리보기를 한 번에 가져온다.
    /// 순서는 요청한 번호 순서를 지킨다 — 스팀 응답 순서에 기대지 않는다.
    public func details(ids: [String]) async throws -> [WorkshopItem] {
        guard !ids.isEmpty else { return [] }
        let bounded = Array(ids.prefix(Self.maxIDsPerPage))

        var body = "itemcount=\(bounded.count)"
        for (index, id) in bounded.enumerated() {
            body += "&publishedfileids%5B\(index)%5D=\(id)"
        }
        var request = URLRequest(
            url: URL(string:
                "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WorkshopError.badResponse(http.statusCode)
        }
        let parsed = try Self.parseDetails(data)
        // 요청 순서 유지. 목록의 정렬이 곧 사용자가 본 순서다.
        let byID = Dictionary(parsed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return bounded.compactMap { byID[$0] }
    }

    static func parseDetails(_ data: Data) throws -> [WorkshopItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]] else {
            throw WorkshopError.malformedPayload
        }
        return files.compactMap { file in
            // result 1이 아니면 삭제됐거나 비공개다. 제목이 없는 항목을 목록에
            // 남기면 사용자가 눌렀을 때 실패한다.
            guard (file["result"] as? Int) == 1,
                  let id = file["publishedfileid"] as? String,
                  let title = file["title"] as? String else { return nil }
            // file_size는 문자열로 올 때와 수로 올 때가 둘 다 있다.
            let size = (file["file_size"] as? Int)
                ?? Int(file["file_size"] as? String ?? "") ?? 0
            let tags = (file["tags"] as? [[String: Any]])?
                .compactMap { $0["tag"] as? String } ?? []
            return WorkshopItem(
                id: id, title: title, sizeBytes: max(0, size),
                previewURL: (file["preview_url"] as? String).flatMap(URL.init(string:)),
                tags: tags)
        }
    }
}
