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

public enum WorkshopSort: String, Sendable, CaseIterable {
    case trend
    case mostrecent
    case totaluniquesubscribers

    public var label: String {
        switch self {
        case .trend: return "인기"
        case .mostrecent: return "최신"
        case .totaluniquesubscribers: return "구독 많은 순"
        }
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
        sort: WorkshopSort = .trend, searchText: String = "", page: Int = 1
    ) async throws -> [String] {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var query = [
            URLQueryItem(name: "appid", value: SteamCmdClient.wallpaperEngineAppID),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "numperpage", value: "\(Self.pageSize)"),
            URLQueryItem(name: "p", value: "\(max(1, page))"),
        ]
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            query.append(URLQueryItem(name: "browsesort", value: sort.rawValue))
        } else {
            // 검색어가 있으면 정렬은 스팀이 관련도로 정한다.
            query.append(URLQueryItem(name: "browsesort", value: "textsearch"))
            query.append(URLQueryItem(name: "searchtext", value: trimmed))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        // 기본 User-Agent로는 스팀이 다른 페이지를 준다.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WorkshopError.badResponse(http.statusCode)
        }
        return Self.parseIDs(from: String(decoding: data, as: UTF8.self))
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
