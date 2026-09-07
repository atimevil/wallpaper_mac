import Foundation
import JavaScriptCore

/// 배경화면이 사용자에게 열어 둔 조절 손잡이 하나.
///
/// 정의는 **`project.json`의 `general.properties`**에 있고, 씬 안의 레이어는
/// `{"user": "이름", "value": …}`로 그것을 가리킨다. 실물 19개를 세어 보니
/// 슬라이더 36·색 26·켜기/끄기 28·콤보 1·글자 입력 2·설명글 4다. 정의를 안
/// 읽으면 씬은 편집기가 저장해 둔 `value`로만 그려지고, 사용자는 색 하나 못
/// 바꾼다 — 실물 Wallpaper Engine이 오른쪽 패널에서 하는 그 일이다.
public struct UserProperty: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case toggle
        case slider(min: Double, max: Double, step: Double)
        case color
        case combo(options: [(label: String, value: String)])
        case textInput
        /// 조절할 수 없는 설명글. 링크·안내가 여기 온다.
        case text
        /// 사용자가 고른 그림·영상으로 레이어의 텍스처를 바꾼다(`scenetexture`).
        /// 값은 파일 경로다. 창작마당 프리셋이 자기 `files/` 안의 파일을 준다.
        case texture

        public static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.toggle, .toggle), (.color, .color), (.textInput, .textInput), (.text, .text),
                 (.texture, .texture):
                return true
            case (.slider(let a, let b, let c), .slider(let d, let e, let f)):
                return a == d && b == e && c == f
            case (.combo(let a), .combo(let b)):
                return a.map(\.value) == b.map(\.value) && a.map(\.label) == b.map(\.label)
            default:
                return false
            }
        }
    }

    public var id: String { name }
    public let name: String
    public let label: String
    public let kind: Kind
    /// 편집기가 저장한 값. 형은 종류마다 다르다(Bool·Double·"r g b"·String).
    public let defaultValue: UserPropertyValue
    public let order: Int
    /// 보일 조건. JS 식이다(`"advanced_settings.value === true"`). 비어 있으면 항상.
    public let condition: String

    public init(name: String, label: String, kind: Kind, defaultValue: UserPropertyValue,
                order: Int, condition: String = "") {
        self.name = name
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.order = order
        self.condition = condition
    }

    /// `project.json`에서 읽는다. 순서(`order`)대로 정렬한다 — 편집기가 보여 주던
    /// 차례가 그것이고, 조건이 앞 항목을 가리키는 것이 보통이다.
    public static func load(projectJSON data: Data) -> [UserProperty] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else { return [] }
        var out: [UserProperty] = []
        for (name, raw) in properties {
            guard let dict = raw as? [String: Any], let type = dict["type"] as? String else {
                continue
            }
            let label = Self.displayLabel(dict["text"] as? String ?? name)
            let order = (dict["order"] as? NSNumber)?.intValue ?? Int.max
            let condition = dict["condition"] as? String ?? ""
            let kind: Kind
            let value: UserPropertyValue
            switch type {
            case "bool":
                kind = .toggle
                value = .toggle((dict["value"] as? NSNumber)?.boolValue ?? false)
            case "slider":
                let lo = (dict["min"] as? NSNumber)?.doubleValue ?? 0
                let hi = (dict["max"] as? NSNumber)?.doubleValue ?? 1
                let step = (dict["step"] as? NSNumber)?.doubleValue ?? 0
                guard lo.isFinite, hi.isFinite, hi > lo else { continue }
                kind = .slider(min: lo, max: hi, step: step.isFinite && step > 0 ? step : 0)
                let stored = (dict["value"] as? NSNumber)?.doubleValue ?? lo
                value = .number(Swift.min(Swift.max(stored, lo), hi))
            case "color":
                kind = .color
                guard let text = dict["value"] as? String, let color = Vec3.parse(text) else {
                    continue
                }
                value = .color(color)
            case "combo":
                let options = ((dict["options"] as? [Any]) ?? []).compactMap {
                    option -> (label: String, value: String)? in
                    guard let o = option as? [String: Any] else { return nil }
                    let label = o["label"] as? String ?? ""
                    // 값은 문자열이거나 수다. 문자열로 통일한다 — 씬이 비교할 때도
                    // 그렇게 비교한다(`mode.value == "clock"`).
                    let raw = o["value"]
                    let value = (raw as? String) ?? (raw as? NSNumber).map { "\($0)" } ?? ""
                    return (label.isEmpty ? value : label, value)
                }
                guard !options.isEmpty else { continue }
                kind = .combo(options: options)
                let raw = dict["value"]
                value = .text((raw as? String) ?? (raw as? NSNumber).map { "\($0)" }
                    ?? options[0].value)
            case "textinput":
                kind = .textInput
                value = .text(dict["value"] as? String ?? "")
            case "text":
                kind = .text
                value = .text("")
            case "scenetexture":
                kind = .texture
                value = .text(dict["value"] as? String ?? "")
            default:
                // 파일·디렉터리 고르기 같은 것은 아직 안 한다. 조용히 빼지 않고
                // 설명글로 남겨 "여기 뭔가 있었다"는 것은 보이게 한다.
                kind = .text
                value = .text("")
            }
            out.append(UserProperty(name: name, label: label, kind: kind,
                                    defaultValue: value, order: order, condition: condition))
        }
        return out.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// 화면에 보일 이름.
    ///
    /// 제작자가 적은 글은 그대로 보인다 — 중국어면 중국어다. 실물 Wallpaper
    /// Engine도 제작자의 글은 번역하지 않는다. 다만 **WE 자신의 지역화 키**
    /// (`ui_browse_properties_scheme_color`)는 WE가 사용자 언어로 보여 주는
    /// 것이라 우리도 그래야 한다. 실물 178개 씬이 이 키를 달고 있다 — WE가
    /// 모든 씬에 자동으로 넣는 "구성표 색"이다. WE는 문자열 표를 assets에
    /// 싣지 않으므로 아는 것만 우리말로 두고, 모르는 키는 날것 대신 사람이
    /// 읽을 수 있게 다듬는다.
    static func displayLabel(_ raw: String) -> String {
        if let known = localizedKeys[raw] { return known }
        if raw.hasPrefix("ui_"), raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            // `ui_editor_properties_foo_bar` → `foo bar`. 접두어는 뜻이 없다.
            var parts = raw.split(separator: "_").map(String.init)
            for prefix in ["ui", "editor", "browse", "scene", "options", "properties"]
            where parts.first == prefix {
                parts.removeFirst()
            }
            return parts.isEmpty ? raw : parts.joined(separator: " ")
        }
        return stripTags(raw)
    }

    /// WE 지역화 키 중 뜻을 아는 것. 실물 한국어 UI에 보이는 이름 그대로다.
    static let localizedKeys: [String: String] = [
        "ui_browse_properties_scheme_color": "구성표 색",
        "ui_editor_scene_options_background_color": "배경색",
        "ui_editor_properties_opacity": "불투명도",
        "ui_editor_properties_strength": "세기",
        "ui_editor_properties_speed": "속도",
        "ui_editor_properties_color": "색",
        "ui_editor_properties_brightness": "밝기",
    ]

    /// 설명글은 HTML이다(`<center><big><b>…<a href=…>`). 태그를 걷어 글만 남긴다.
    static func stripTags(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in html {
            if character == "<" { inTag = true; continue }
            if character == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 보일 조건을 판정한다. 조건은 JS 식이라 JavaScriptCore에 맡긴다.
    ///
    /// 식 안에서 `이름.value`로 다른 속성을 읽는다. 값은 우리가 넣어 주는 것만
    /// 보이고, 그 밖에는 아무것도 없는 문맥이다 — 창작마당 파일에서 온 식이라
    /// 믿을 수 없고, 시간을 끌면 창이 굳으므로 짧게 자른다.
    /// 판정할 수 없으면 **보인다**. 숨겼다가 틀리면 사용자가 손잡이를 잃는다.
    public static func isVisible(
        _ property: UserProperty, values: [String: UserPropertyValue]
    ) -> Bool {
        let condition = property.condition.trimmingCharacters(in: .whitespaces)
        guard !condition.isEmpty, condition.utf8.count <= 2048 else { return true }
        guard let context = JSContext() else { return true }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        for (name, value) in values {
            // 이름은 JS 식별자여야 한다. 아니면 그 속성은 식에서 못 보게 둔다.
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  let first = name.first, !first.isNumber else { continue }
            let holder = JSValue(newObjectIn: context)
            holder?.setValue(value.jsValue(in: context), forProperty: "value")
            context.setObject(holder, forKeyedSubscript: name as NSString)
        }
        let result = context.evaluateScript("Boolean(\(condition))")
        guard !failed, let result, result.isBoolean else { return true }
        return result.toBool()
    }
}

/// 속성의 값. 종류에 따라 하나만 쓴다.
public enum UserPropertyValue: Equatable, Sendable {
    case toggle(Bool)
    case number(Double)
    case color(Vec3)
    case text(String)

    /// 씬 JSON의 `value` 자리에 넣을 꼴. 파서가 기대하는 형과 맞아야 한다 —
    /// 색은 `"r g b"` 문자열, 켜기/끄기는 Bool, 수는 Double이다.
    public var sceneJSONValue: Any {
        switch self {
        case .toggle(let b): return b
        case .number(let d): return d
        case .color(let c): return "\(c.x) \(c.y) \(c.z)"
        case .text(let s): return s
        }
    }

    func jsValue(in context: JSContext) -> JSValue? {
        switch self {
        case .toggle(let b): return JSValue(bool: b, in: context)
        case .number(let d): return JSValue(double: d, in: context)
        case .color(let c): return JSValue(object: "\(c.x) \(c.y) \(c.z)", in: context)
        case .text(let s): return JSValue(object: s, in: context)
        }
    }

    /// 프리셋(`project.json`의 `preset`)이나 씬 JSON에 있는 날것을 속성 종류에 맞춰 읽는다.
    /// 맞지 않는 값은 nil — 기본값이 남는다.
    public static func parse(preset raw: Any, kind: UserProperty.Kind) -> UserPropertyValue? {
        switch kind {
        case .toggle:
            guard let n = raw as? NSNumber else { return nil }
            return .toggle(n.boolValue)
        case .slider(let lo, let hi, _):
            guard let n = raw as? NSNumber, !(raw is String), n.doubleValue.isFinite else { return nil }
            return .number(Swift.min(Swift.max(n.doubleValue, lo), hi))
        case .color:
            guard let text = raw as? String, let color = Vec3.parse(text) else { return nil }
            return .color(color)
        case .combo, .textInput, .texture:
            if let text = raw as? String { return .text(text) }
            if let n = raw as? NSNumber { return .text("\(n)") }
            return nil
        case .text:
            return nil
        }
    }

    /// 저장용. JSON에 넣을 수 있는 꼴로 종류 표시와 함께 싼다.
    var stored: [String: Any] {
        switch self {
        case .toggle(let b): return ["kind": "toggle", "value": b]
        case .number(let d): return ["kind": "number", "value": d]
        case .color(let c): return ["kind": "color", "value": [c.x, c.y, c.z]]
        case .text(let s): return ["kind": "text", "value": s]
        }
    }

    static func from(stored raw: Any) -> UserPropertyValue? {
        guard let dict = raw as? [String: Any], let kind = dict["kind"] as? String else {
            return nil
        }
        switch kind {
        case "toggle": return (dict["value"] as? NSNumber).map { .toggle($0.boolValue) }
        case "number":
            guard let d = (dict["value"] as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            return .number(d)
        case "color":
            guard let parts = dict["value"] as? [NSNumber], parts.count == 3 else { return nil }
            let v = parts.map(\.doubleValue)
            guard v.allSatisfy(\.isFinite) else { return nil }
            return .color(Vec3(x: v[0], y: v[1], z: v[2]))
        case "text": return (dict["value"] as? String).map { .text($0) }
        default: return nil
        }
    }
}

/// 사용자가 바꾼 값을 배경화면마다 파일 하나에 둔다.
///
/// `<root>/<아이템 번호>.json`. 라이브러리 폴더에는 안 쓴다 — 그쪽은 받아 둔
/// 원본이고, "지우기"가 통째로 지운다. 설정은 원본과 따로 살아야 다시 받아도
/// 남는다.
public struct UserPropertyStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func file(for id: String) -> URL {
        // 번호가 아닌 이름은 경로로 쓰지 않는다. `..` 같은 것이 들어오면 안 된다.
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return root.appendingPathComponent((safe.isEmpty ? "_" : safe) + ".json")
    }

    public func overrides(for id: String) -> [String: UserPropertyValue] {
        guard let data = try? Data(contentsOf: file(for: id)),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var out: [String: UserPropertyValue] = [:]
        for (name, raw) in dict {
            if let value = UserPropertyValue.from(stored: raw) { out[name] = value }
        }
        return out
    }

    public func save(_ overrides: [String: UserPropertyValue], for id: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if overrides.isEmpty {
            try? FileManager.default.removeItem(at: file(for: id))
            return
        }
        let dict = overrides.mapValues(\.stored)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: file(for: id), options: .atomic)
    }
}
