import XCTest
@testable import WallflowKit

/// 배경화면이 사용자에게 열어 둔 조절 손잡이 — 정의는 `project.json`에, 참조는
/// 씬 안에 `{"user": "이름", "value": …}`로 있다. 실물 19개에서 슬라이더 36·
/// 색 26·켜기/끄기 28을 셌다. 이걸 안 읽으면 사용자는 색 하나 못 바꾼다.
final class UserPropertyTests: XCTestCase {
    private let project = """
    {"general": {"properties": {
        "custom_colors": {"order": 100, "text": "Custom colors", "type": "bool", "value": false},
        "orb_color": {"order": 105, "text": "Orb Color", "type": "color",
                      "value": "0.639 0.937 1", "condition": "custom_colors.value === true"},
        "center": {"order": 111, "text": "Center", "type": "slider",
                   "min": 0, "max": 1, "step": 0.025, "value": 0.42},
        "mode": {"order": 90, "text": "Mode", "type": "combo", "value": "clock",
                 "options": [{"label": "Clock", "value": "clock"}, {"label": "Orbs", "value": "orbs"}]},
        "bgm": {"order": 114, "text": "音乐BGM：", "type": "textinput", "value": "酣梦"},
        "link": {"order": 101, "type": "text",
                 "text": "<center><big><b>🔻壁纸获取🔻<br/><a href='x'>링크</a></b></big></center>"}
    }}}
    """

    func testParsesEveryKindInOrder() throws {
        let props = UserProperty.load(projectJSON: Data(project.utf8))
        XCTAssertEqual(props.map(\.name), ["mode", "custom_colors", "link", "orb_color", "center", "bgm"],
                       "편집기 순서(order)대로")
        XCTAssertEqual(props[1].kind, .toggle)
        XCTAssertEqual(props[1].defaultValue, .toggle(false))
        XCTAssertEqual(props[3].kind, .color)
        XCTAssertEqual(props[3].defaultValue, .color(Vec3(x: 0.639, y: 0.937, z: 1)))
        XCTAssertEqual(props[3].condition, "custom_colors.value === true")
        XCTAssertEqual(props[4].kind, .slider(min: 0, max: 1, step: 0.025))
        XCTAssertEqual(props[4].defaultValue, .number(0.42))
        guard case .combo(let options) = props[0].kind else { return XCTFail("combo여야 한다") }
        XCTAssertEqual(options.map(\.value), ["clock", "orbs"])
        XCTAssertEqual(props[5].kind, .textInput)
        XCTAssertEqual(props[5].defaultValue, .text("酣梦"))
    }

    /// 설명글은 HTML이다. 태그를 걷어 글만 남긴다.
    func testStaticTextIsStrippedOfTags() {
        let props = UserProperty.load(projectJSON: Data(project.utf8))
        let link = try? XCTUnwrap(props.first { $0.name == "link" })
        XCTAssertEqual(link?.kind, .text)
        XCTAssertEqual(link?.label, "🔻壁纸获取🔻 링크")
    }

    /// 제작자의 글은 그대로, WE의 지역화 키는 우리말로, 모르는 키는 읽을 수 있게.
    /// 실물 178개 씬이 `ui_browse_properties_scheme_color`를 달고 있다 —
    /// 날것으로 보이면 사용자는 그게 무슨 손잡이인지 알 수 없다.
    func testLabelsLocalizeWEKeysButKeepAuthorText() {
        XCTAssertEqual(UserProperty.displayLabel("ui_browse_properties_scheme_color"), "구성표 색")
        XCTAssertEqual(UserProperty.displayLabel("音频条颜色"), "音频条颜色", "제작자 글은 번역하지 않는다")
        XCTAssertEqual(UserProperty.displayLabel("ui_editor_properties_glow_radius"), "glow radius",
                       "모르는 키는 접두어를 떼고 읽을 수 있게")
        XCTAssertEqual(UserProperty.displayLabel("<b>Orb</b> Color"), "Orb Color")
        let json = #"{"general":{"properties":{"schemecolor":{"type":"color","value":"1 1 1","text":"ui_browse_properties_scheme_color"}}}}"#
        XCTAssertEqual(UserProperty.load(projectJSON: Data(json.utf8)).first?.label, "구성표 색")
    }

    /// 슬라이더 값은 범위 안으로 죈다. 파일이 이상한 값을 줘도 손잡이가 밖으로 안 나간다.
    func testSliderValueIsClamped() {
        let json = #"{"general":{"properties":{"s":{"type":"slider","min":0,"max":10,"value":99}}}}"#
        let props = UserProperty.load(projectJSON: Data(json.utf8))
        XCTAssertEqual(props.first?.defaultValue, .number(10))
    }

    /// 조건은 JS 식이다. 다른 속성의 값으로 판정하고, 판정할 수 없으면 **보인다**.
    func testConditionIsEvaluatedAgainstOtherValues() {
        let props = UserProperty.load(projectJSON: Data(project.utf8))
        let orb = props.first { $0.name == "orb_color" }!
        XCTAssertFalse(UserProperty.isVisible(orb, values: ["custom_colors": .toggle(false)]))
        XCTAssertTrue(UserProperty.isVisible(orb, values: ["custom_colors": .toggle(true)]))
        // 문자열 비교도 된다(`mode.value == "clock"`).
        let gated = UserProperty(name: "g", label: "g", kind: .toggle, defaultValue: .toggle(true),
                                 order: 0, condition: #"mode.value == "clock" && center.value > 0.3"#)
        XCTAssertTrue(UserProperty.isVisible(gated, values: ["mode": .text("clock"), "center": .number(0.42)]))
        XCTAssertFalse(UserProperty.isVisible(gated, values: ["mode": .text("orbs"), "center": .number(0.42)]))
        // 깨진 식, 모르는 이름은 보인다 — 숨겼다가 틀리면 손잡이를 잃는다.
        let broken = UserProperty(name: "b", label: "b", kind: .toggle, defaultValue: .toggle(true),
                                  order: 0, condition: "nope.value ===")
        XCTAssertTrue(UserProperty.isVisible(broken, values: [:]))
        XCTAssertTrue(UserProperty.isVisible(broken, values: ["x": .number(1)]))
    }

    /// 식은 창작마당 파일에서 온다. 바깥세상은 아무것도 못 본다.
    func testConditionCannotReachOutsideItsSandbox() {
        let probe = UserProperty(name: "p", label: "p", kind: .toggle, defaultValue: .toggle(true),
                                 order: 0, condition: "typeof require === 'undefined' && typeof process === 'undefined'")
        XCTAssertTrue(UserProperty.isVisible(probe, values: [:]))
    }

    // MARK: 저장

    func testStoreRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-props-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserPropertyStore(root: root)
        let values: [String: UserPropertyValue] = [
            "custom_colors": .toggle(true), "center": .number(0.75),
            "orb_color": .color(Vec3(x: 1, y: 0.5, z: 0)), "bgm": .text("노래"),
        ]
        try store.save(values, for: "12345")
        XCTAssertEqual(store.overrides(for: "12345"), values)
        XCTAssertEqual(store.overrides(for: "99999"), [:], "없는 것은 빈 값")
        // 비우면 파일이 사라진다.
        try store.save([:], for: "12345")
        XCTAssertEqual(store.overrides(for: "12345"), [:])
    }

    /// 아이템 번호는 경로가 된다. `..`로 밖에 쓰면 안 된다.
    func testStoreSanitizesTheID() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-props-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserPropertyStore(root: root)
        try store.save(["a": .toggle(true)], for: "../../escape")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertEqual(written, ["escape.json"])
    }

    // MARK: 씬에 얹기

    /// 트리를 한 번 훑어 `value`만 바꿔치기한다. 레이어 색이든 이펙트 상수든
    /// 보임이든 자리를 가리지 않는다 — 파서를 하나도 안 건드리고 전부에 먹는다.
    func testOverridesReplaceValuesAnywhereInTheTree() throws {
        let scene: [String: Any] = [
            "objects": [
                ["id": 1, "name": "L",
                 "visible": ["user": "particles", "value": false],
                 "color": ["user": "tint", "value": "1 1 1"],
                 "effects": [["passes": [["constantshadervalues":
                    ["strength": ["user": "grain", "value": 0.0]]]]]]],
            ],
        ]
        let out = SceneDocument.applyingUserOverrides(scene, overrides: [
            "particles": .toggle(true), "tint": .color(Vec3(x: 1, y: 0, z: 0)),
            "grain": .number(0.8), "unused": .number(9),
        ]) as? [String: Any]
        let layer = try XCTUnwrap((out?["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual((layer["visible"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((layer["color"] as? [String: Any])?["value"] as? String, "1.0 0.0 0.0")
        let effects = layer["effects"] as? [[String: Any]]
        let passes = effects?.first?["passes"] as? [[String: Any]]
        let constants = passes?.first?["constantshadervalues"] as? [String: Any]
        let strength = constants?["strength"] as? [String: Any]
        XCTAssertEqual(strength?["value"] as? Double, 0.8)
        XCTAssertEqual(strength?["user"] as? String, "grain", "참조 이름은 그대로")
    }

    /// 실제 파서까지 통과해야 뜻이 있다. 보임을 켜면 레이어가 살아난다.
    func testOverrideReachesTheParsedLayer() throws {
        let json = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "L", "origin": "0 0 0", "size": "10 10",
                      "image": "materials/a.json",
                      "visible": {"user": "show", "value": false},
                      "color": {"user": "tint", "value": "1 1 1"}}]}
        """
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data(json.utf8)),
            ("materials/a.json", Data(#"{"passes": [{"shader": "s", "textures": ["t"]}]}"#.utf8)),
        ]))
        let plain = try SceneDocument.load(from: pkg, assets: nil)
        XCTAssertEqual(plain.layers.first?.visible, false)
        let overridden = try SceneDocument.load(
            from: pkg, assets: nil,
            userOverrides: ["show": .toggle(true), "tint": .color(Vec3(x: 0, y: 1, z: 0))])
        XCTAssertEqual(overridden.layers.first?.visible, true)
        XCTAssertEqual(overridden.layers.first?.tint, Vec3(x: 0, y: 1, z: 0))
    }

    // MARK: 재생 규칙

    /// 기본값은 지금의 고정 동작과 같아야 한다. 하나도 안 바꾸면 전원 60·배터리 30이다.
    func testStandardPreferencesMatchOldBehaviour() {
        XCTAssertEqual(PowerPolicy.directive(for: PowerSignals(isOccluded: true)), .paused)
        XCTAssertEqual(PowerPolicy.directive(for: PowerSignals(isFullscreenAppActive: true)), .paused)
        XCTAssertEqual(PowerPolicy.directive(for: PowerSignals(idleSeconds: 900)), .paused)
        XCTAssertEqual(PowerPolicy.directive(for: PowerSignals(isOnBattery: true)), .playing(fps: 30))
        XCTAssertEqual(PowerPolicy.directive(for: .active), .playing(fps: 60))
    }

    func testPreferencesCanKeepPlaying() {
        var prefs = PowerPreferences()
        prefs.pauseWhenOccluded = false
        prefs.pauseInFullscreen = false
        prefs.idlePauseSeconds = 0
        prefs.batteryFPS = 60
        prefs.targetFPS = 60
        let busy = PowerSignals(isOccluded: true, isFullscreenAppActive: true,
                                idleSeconds: 99999, isOnBattery: true)
        XCTAssertEqual(PowerPolicy.directive(for: busy, preferences: prefs), .playing(fps: 60))
    }

    /// 발열은 사용자가 끌 수 없다. 기계를 지키는 쪽이 우선이다.
    func testThermalPressureAlwaysReduces() {
        var prefs = PowerPreferences()
        prefs.batteryFPS = 60
        prefs.targetFPS = 60
        XCTAssertEqual(
            PowerPolicy.directive(for: PowerSignals(isThermallyPressured: true), preferences: prefs),
            .playing(fps: 15))
    }

    /// 허용된 프레임만 받는다. 파일이 이상한 값을 줘도 기본값으로 돌아간다.
    func testUnknownFPSFallsBackToNormal() {
        var prefs = PowerPreferences()
        prefs.targetFPS = 1000
        XCTAssertEqual(PowerPolicy.directive(for: .active, preferences: prefs), .playing(fps: 60))
    }
}
