import Foundation

/// 사이드바의 필터 구획. 같은 구획 안에서 여럿 고르면 종류·등급·해상도는
/// "그중 하나"(OR)이고, 장르·특성은 "전부 다"(AND)다 — 스팀 `requiredtags[]`가
/// 이미 AND라서 장르·특성은 그대로 요청에 실어도 되지만, OR는 서버가 걸러줄 수
/// 없어 하나만 골랐을 때만 요청에 싣고 둘 이상이면 받아 온 뒤 여기서 거른다.
public enum WorkshopFilterSection: String, CaseIterable, Hashable, Sendable {
    case kind, rating, resolution, genre, flag

    /// 같은 섹션에서 여럿 고르면 "그중 하나"인지.
    public var isAnyOf: Bool { self == .kind || self == .rating || self == .resolution }

    /// 이 섹션의 고를 거리. `WorkshopTag`에서 빈 태그("모든…")를 뺀 것.
    public var choices: [WorkshopTag.Choice] {
        let all: [WorkshopTag.Choice]
        switch self {
        case .kind: all = WorkshopTag.kinds
        case .rating: all = WorkshopTag.ratings
        case .resolution: all = WorkshopTag.resolutions
        case .genre: all = WorkshopTag.genres
        case .flag: all = WorkshopTag.flags
        }
        return all.filter { !$0.tag.isEmpty }
    }
}

/// 사이드바 필터 전체 상태 — 판정만 하는 순수 값 타입.
public struct WorkshopFilterState: Equatable, Sendable {
    public var selected: [WorkshopFilterSection: Set<String>]
    public var hideInstalled: Bool

    public init() {
        self.selected = [.rating: ["Everyone"]]
        self.hideInstalled = false
    }

    public mutating func toggle(_ tag: String, in section: WorkshopFilterSection) {
        var set = selected[section] ?? []
        if !set.insert(tag).inserted {
            set.remove(tag)
        }
        selected[section] = set.isEmpty ? nil : set
    }

    public mutating func reset() {
        self = WorkshopFilterState()
    }

    /// Steam 요청에 실을 조건. OR 섹션(종류·등급·해상도)은 하나만 골랐을 때만
    /// 싣는다 — 둘 이상이면 서버가 AND로 걸러 결과가 통째로 비게 된다.
    /// AND 섹션(장르·특성)은 여럿이어도 그대로 싣는다.
    public var requestFilter: WorkshopFilter {
        var tags: [String] = []
        for section in WorkshopFilterSection.allCases {
            let set = selected[section] ?? []
            guard !set.isEmpty else { continue }
            if section.isAnyOf {
                if set.count == 1 { tags.append(contentsOf: set) }
            } else {
                tags.append(contentsOf: set)
            }
        }
        return WorkshopFilter(tags: tags)
    }

    /// 받아 온(또는 설치된) 항목이 조건에 맞는지. OR 섹션에서 둘 이상 골랐을
    /// 때는 서버가 거르지 못하므로 여기서 거른다.
    ///
    /// `ignoring`에 넣은 섹션은 판정에서 빼 버린다. 라이브러리(설치됨 탭)는
    /// `[.resolution]`을 넘긴다 — 해상도는 project.json 어디에도 없어서, 넣은
    /// 채로 판정하면 해상도를 하나라도 고른 순간 설치된 항목이 전부 빠진다.
    public func matches(tags itemTags: [String], ignoring: Set<WorkshopFilterSection> = []) -> Bool {
        let lowered = Set(itemTags.map { $0.lowercased() })
        for section in WorkshopFilterSection.allCases where !ignoring.contains(section) {
            let set = selected[section] ?? []
            guard !set.isEmpty else { continue }
            let wanted = Set(set.map { $0.lowercased() })
            if section.isAnyOf {
                guard !wanted.isDisjoint(with: lowered) else { return false }
            } else {
                guard wanted.isSubset(of: lowered) else { return false }
            }
        }
        return true
    }

    /// 캐시 키. 섹션·태그 모두 정렬해 고른 순서가 달라도 같은 조건이면 같다.
    public var key: String {
        WorkshopFilterSection.allCases
            .map { section -> String in
                let tags = (selected[section] ?? []).sorted().joined(separator: ",")
                return "\(section.rawValue)=\(tags)"
            }
            .joined(separator: ";") + ";hideInstalled=\(hideInstalled)"
    }
}
