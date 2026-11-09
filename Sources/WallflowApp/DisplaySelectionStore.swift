import Foundation

/// 화면마다 따로 건 배경(`[화면 키: 배경 id]`)을 UserDefaults에 둔다. 순수 로직은
/// `DisplaySelection`(Kit). "모든 화면" 배경은 예전 그대로 `wallflow.lastSelectedID`.
enum DisplaySelectionStore {
    static let key = "wallflow.selectionByDisplay"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ map: [String: String]) {
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(map, forKey: key)
        }
    }
}
