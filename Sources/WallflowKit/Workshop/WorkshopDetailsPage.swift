import Foundation

/// 창작마당 상세 페이지에서 긁은 것. 목록 API에는 평점·작성자가 없다.
///
/// 페이지 모양이 바뀌면 여기만 못 읽는다 — 나머지 패널(설명·구독 수 등)은
/// 목록 API로 채우니 그대로 뜬다(Review Focus 3).
public struct WorkshopDetailsPage: Equatable, Sendable {
    /// 0~5, 0.5 단위. 별 이미지 파일명(`4-star_large.png`, `3_half-star_large.png`)에서 읽는다.
    public var rating: Double?
    public var ratingCount: Int?
    public var author: String?

    public init(rating: Double? = nil, ratingCount: Int? = nil, author: String? = nil) {
        self.rating = rating
        self.ratingCount = ratingCount
        self.author = author
    }

    public static func parse(html: String) -> WorkshopDetailsPage {
        var page = WorkshopDetailsPage()

        if let starMatch = firstMatch(#"(\d)(_half)?-star_large"#, in: html) {
            let whole = Double(starMatch.group(1) ?? "") ?? 0
            page.rating = whole + (starMatch.group(2) != nil ? 0.5 : 0)
        }
        if let countMatch = firstMatch(#"numRatings">([\d,]+) ratings"#, in: html) {
            page.ratingCount = Int((countMatch.group(1) ?? "").replacingOccurrences(of: ",", with: ""))
        }
        if let authorMatch = firstMatch(#"friendBlockContent">\s*([^<]+?)\s*<br"#, in: html) {
            page.author = authorMatch.group(1)
        }
        return page
    }

    /// 정규식 한 번 돌려 첫 매치의 캡처 그룹을 꺼낸다.
    private static func firstMatch(_ pattern: String, in html: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let result = regex.firstMatch(in: html, range: range) else { return nil }
        return Match(text: html, result: result)
    }

    private struct Match {
        let text: String
        let result: NSTextCheckingResult
        func group(_ index: Int) -> String? {
            guard let r = Range(result.range(at: index), in: text) else { return nil }
            return String(text[r])
        }
    }
}

/// 창작마당 설명에 쓰는 스팀 BBCode를 평문으로 바꾼다.
public enum WorkshopText {
    public static func plain(fromBBCode input: String) -> String {
        var text = input
        // [img]…[/img]는 내용째 지운다 — 평문에 그림 경로가 남을 이유가 없다.
        text = replacing(#"\[img\].*?\[/img\]"#, in: text, with: "")
        text = replacing(#"\[/?[bui]\]"#, in: text, with: "")
        text = replacing(#"\[/?h1\]"#, in: text, with: "")
        text = replacing(#"\[url=[^\]]*\](.*?)\[/url\]"#, in: text, with: "$1")
        text = replacing(#"\[list\]"#, in: text, with: "")
        text = replacing(#"\[/list\]"#, in: text, with: "")
        text = replacing(#"\[\*\]"#, in: text, with: "\n• ")
        // 남은 태그(모르는 것 포함)는 통째로 제거한다.
        text = replacing(#"\[/?[a-zA-Z0-9=:/. \-]+\]"#, in: text, with: "")
        return text
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// 무한 스크롤 페이지를 이어붙인다. id 중복은 먼저 온 것을 지키고, 순서는 유지한다.
public enum WorkshopPaging {
    public static func merge(_ existing: [WorkshopItem], _ page: [WorkshopItem]) -> [WorkshopItem] {
        var seen = Set(existing.map(\.id))
        var merged = existing
        for item in page where seen.insert(item.id).inserted {
            merged.append(item)
        }
        return merged
    }
}
