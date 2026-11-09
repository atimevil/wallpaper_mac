import Foundation

/// 화면마다 따로 건 배경의 저장 모델(순수). 사전은 `[화면 키: 배경 id]`.
///
/// "모든 화면" 배경은 따로(`wallflow.lastSelectedID`) 둔다 — 화면별 지정이 없는 화면은 그걸 쓴다.
/// 화면 키는 `CGDisplayCreateUUIDFromDisplayID` 문자열이다(`CGDirectDisplayID`는 재연결·재부팅 때
/// 바뀔 수 있다). 같은 모델 모니터 두 대는 UUID가 겹칠 수 있어 순번을 붙여 구별한다.
public enum DisplaySelection {
    /// 화면 순서대로 받은 UUID를 저장 키로 바꾼다. 겹치면 두 번째부터 `UUID#2`, `UUID#3`.
    public static func keys(forUUIDs uuids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return uuids.map { uuid in
            let n = (seen[uuid] ?? 0) + 1
            seen[uuid] = n
            return n == 1 ? uuid : "\(uuid)#\(n)"
        }
    }

    /// 이 화면에 걸 배경 id. 화면별 지정이 있으면 그것, 없으면 "모든 화면" 배경.
    public static func itemID(forDisplay key: String, in map: [String: String],
                              default fallback: String?) -> String? {
        map[key] ?? fallback
    }

    public static func setting(_ id: String, forDisplay key: String,
                               in map: [String: String]) -> [String: String] {
        var out = map
        out[key] = id
        return out
    }

    /// "모든 화면"에 걸 때: **지금 연결된** 화면의 지정만 지운다. 꺼져 있는 모니터 설정은 남긴다.
    public static func clearing(displays keys: [String], in map: [String: String]) -> [String: String] {
        map.filter { !keys.contains($0.key) }
    }

    /// 지운 배경을 가리키는 지정을 뺀다.
    public static func removing(itemID id: String, in map: [String: String]) -> [String: String] {
        map.filter { $0.value != id }
    }
}
