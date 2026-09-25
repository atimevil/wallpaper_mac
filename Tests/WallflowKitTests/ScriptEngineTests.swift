import XCTest
@testable import WallflowKit

final class ScriptEngineTests: XCTestCase {
    /// 실물 Hiyuki 씬의 시계 스크립트를 줄인 것. 모양이 그대로다 —
    /// `export`, `createScriptProperties()` 빌더, `update(value)` 진입점.
    private let realClockScript = """
    'use strict';
    export let __workshopId = '3692599672';

    export var scriptProperties = createScriptProperties()
        .addCheckbox({ name: 'use24hFormat', label: 'ui_x', value: true })
        .addCheckbox({ name: 'showSeconds', label: 'ui_y', value: false });

    export function update(value) {
        let time = new Date();
        var hours = time.getHours();
        if (!scriptProperties.use24hFormat) {
            hours %= 12;
            if (hours == 0) { hours = 12; }
        }
        hours = ("00" + hours).slice(-2);
        let minutes = ("00" + time.getMinutes()).slice(-2);
        value = hours + scriptProperties.delimiter + minutes;
        return value;
    }
    """

    func testRunsRealClockScript() {
        let engine = ScriptEngine(
            source: realClockScript,
            properties: ["use24hFormat": 1, "showSeconds": 0, "delimiter": ":"])
        XCTAssertNil(engine.failure, "\(String(describing: engine.failure))")
        let result = try? XCTUnwrap(engine.update(value: "Time"))
        XCTAssertNotNil(result)
        // 실제 시각과 맞아야 한다. 문자열 모양만 보면 파서가 틀려도 통과한다.
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let expected = String(format: "%02d:%02d", now.hour!, now.minute!)
        XCTAssertEqual(result, expected)
    }

    /// 레이어의 scriptproperties가 스크립트 안의 빌더를 이겨야 한다.
    /// 안 그러면 `scriptProperties.delimiter`가 undefined가 되어
    /// 시계가 `12undefined34`로 나온다. 실제로 이 모양의 버그가 나기 쉽다.
    func testLayerPropertiesOverrideTheBuilder() throws {
        let engine = ScriptEngine(
            source: realClockScript,
            properties: ["use24hFormat": 1, "delimiter": "-"])
        let result = try XCTUnwrap(engine.update(value: ""))
        XCTAssertFalse(result.contains("undefined"), "빌더가 값을 이겼다: \(result)")
        XCTAssertTrue(result.contains("-"), "delimiter가 반영되지 않았다: \(result)")
    }

    /// properties가 비면 빌더가 남아 delimiter가 undefined가 된다.
    /// 그 경우에도 죽지 않고 문자열을 돌려주기만 하면 된다 — 실패가 아니라 값의 문제다.
    func testMissingPropertiesDoesNotCrash() {
        let engine = ScriptEngine(source: realClockScript)
        XCTAssertNil(engine.failure)
        XCTAssertNotNil(engine.update(value: ""))
    }

    func testStripsOnlyLeadingExport() {
        let source = """
        export function update(value) {
            return "export is a word " + value;
        }
        """
        XCTAssertEqual(
            ScriptEngine.stripModuleSyntax(source),
            """
            function update(value) {
                return "export is a word " + value;
            }
            """,
            "문자열 안의 export를 건드리면 안 된다")
    }

    func testKeepsIndentationWhenStripping() {
        XCTAssertEqual(
            ScriptEngine.stripModuleSyntax("    export let x = 1;"), "    let x = 1;")
    }

    /// 원래 규칙은 줄 맨 앞의 `export`만 봐서, 앞 문장과 세미콜론으로 한 줄에
    /// 있으면 놓쳤다. JavaScriptCore가 SyntaxError를 던지고 유닛이 조용히
    /// 등록 실패한다(`SceneScriptHostTests`에 이 한계를 피하려고 줄을 나눠
    /// 쓴 흔적이 남아 있다).
    func testStripsExportAfterSemicolonOnSameLine() {
        XCTAssertEqual(
            ScriptEngine.stripModuleSyntax("let done = false; export function update(v) { return v; }"),
            "let done = false; function update(v) { return v; }")
    }

    /// `;` 뿐 아니라 `}` 뒤에 이어지는 export도 같은 이유로 지워야 한다.
    func testStripsExportAfterClosingBraceOnSameLine() {
        XCTAssertEqual(
            ScriptEngine.stripModuleSyntax("function helper() {} export function update(v) { return v; }"),
            "function helper() {} function update(v) { return v; }")
    }

    /// 문자열 치환만 맞고 JavaScriptCore가 여전히 못 읽으면 의미가 없다 —
    /// 실제로 엔진에 올라가 등록되고 update가 불리는지까지 확인한다.
    func testOneLineScriptWithMidLineExportRegistersAndRuns() {
        let engine = ScriptEngine(source: "let done = false; export function update(v) { return v; }")
        XCTAssertNil(engine.failure, "\(String(describing: engine.failure))")
        XCTAssertEqual(engine.update(value: "hi"), "hi")
    }

    func testScriptWithoutUpdateIsReported() {
        let engine = ScriptEngine(source: "var x = 1;")
        XCTAssertEqual(engine.failure, .noUpdateFunction)
        XCTAssertNil(engine.update(value: "그대로"))
    }

    func testSyntaxErrorIsReportedNotFatal() {
        let engine = ScriptEngine(source: "function update( { syntax error")
        guard case .evaluationFailed = engine.failure else {
            return XCTFail("평가 실패로 보고해야 한다: \(String(describing: engine.failure))")
        }
    }

    /// update 안에서 던져도 배경화면이 죽으면 안 된다. 값은 바꾸지 않는다.
    func testThrowingUpdateKeepsPreviousValue() {
        let engine = ScriptEngine(source: """
        export function update(value) { throw new Error("펑"); }
        """)
        XCTAssertNil(engine.failure, "본문 평가는 성공해야 한다")
        XCTAssertNil(engine.update(value: "이전"), "실패하면 nil을 돌려 호출자가 값을 유지한다")
        guard case .updateFailed = engine.failure else {
            return XCTFail("update 실패로 보고해야 한다: \(String(describing: engine.failure))")
        }
    }

    /// 글자 하나가 텍스처가 되므로 길이가 곧 메모리다.
    /// 창작마당 스크립트가 1000만 글자를 돌려줄 수 있다.
    func testAbsurdlyLongResultIsTruncated() throws {
        let engine = ScriptEngine(source: """
        export function update(value) { return "가".repeat(10000000); }
        """)
        let result = try XCTUnwrap(engine.update(value: ""))
        XCTAssertEqual(result.count, ScriptEngine.maxResultLength)
    }

    /// 문자열이 아닌 값을 돌려줘도 문자열로 받아야 한다.
    func testNonStringResultIsConverted() throws {
        let engine = ScriptEngine(source: """
        export function update(value) { return 42; }
        """)
        XCTAssertEqual(try XCTUnwrap(engine.update(value: "")), "42")
    }

    /// undefined를 돌려주는 스크립트가 있다. 값을 바꾸지 않아야 한다.
    func testUndefinedResultKeepsValue() {
        let engine = ScriptEngine(source: """
        export function update(value) { }
        """)
        XCTAssertNil(engine.update(value: "그대로"))
    }

    /// 빌더에 무엇을 불러도 죽지 않아야 한다. 우리가 모르는 add* 이름이 오면
    /// 스크립트 평가가 통째로 실패해 레이어가 사라진다.
    func testUnknownBuilderMethodDoesNotBreakEvaluation() {
        let engine = ScriptEngine(source: """
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'a', value: true })
            .addSlider({ name: 'b', value: 1 });
        export function update(value) { return "ok"; }
        """)
        XCTAssertNil(engine.failure, "\(String(describing: engine.failure))")
        XCTAssertEqual(engine.update(value: ""), "ok")
    }
}

extension ScriptEngineTests {
    /// 실물 Deltarune 씬의 미디어 위젯 스크립트를 그대로 옮긴 것.
    /// 음악이 안 나오면 스스로 숨는다 — 이벤트를 안 보내면 저장된 alpha로 그려져
    /// 배경화면 위에 반투명한 검은 상자가 남는다.
    func testMediaWidgetHidesItselfWhenNothingIsPlaying() throws {
        let engine = ScriptEngine(source: """
        'use strict';
        export function init(value) {
            thisLayer.isUserHidden = (value === false);
            thisLayer.visible = true;
            thisLayer.alpha = thisLayer.isUserHidden ? 0 : 1;
            return value;
        }
        export function mediaPlaybackChanged(event) {
            if (thisLayer.isUserHidden) { thisLayer.alpha = 0; return; }
            let isPlaying = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
            thisLayer.alpha = isPlaying ? 1 : 0;
        }
        """)
        let state = try XCTUnwrap(
            engine.runLayerCallbacks(initial: LayerScriptState(alpha: 0.5, visible: true)))
        XCTAssertEqual(state.alpha, 0, "재생 중이 아니면 숨어야 한다")
    }

    /// 썸네일 콜백만 있는 스크립트도 있다(실물 alpha 스크립트).
    func testThumbnailCallbackAlsoRuns() throws {
        let engine = ScriptEngine(source: """
        export function mediaThumbnailChanged(event) {
            if (thisLayer.visible == true) {
                thisLayer.alpha = 0;
                thisObject.getAnimation().play();
            }
        }
        """)
        let state = try XCTUnwrap(
            engine.runLayerCallbacks(initial: LayerScriptState(alpha: 1, visible: true)))
        XCTAssertEqual(state.alpha, 0)
    }

    /// 콜백이 하나도 없으면 아무것도 바꾸지 않는다.
    /// 있지도 않은 근거로 레이어를 숨기면 안 된다.
    func testNoCallbacksLeavesStateAlone() {
        let engine = ScriptEngine(source: "export function update(v) { return v; }")
        XCTAssertNil(engine.runLayerCallbacks(initial: LayerScriptState(alpha: 1, visible: true)))
    }

    /// 콜백 안에서 던져도 죽지 않아야 한다.
    func testThrowingCallbackIsSurvivable() {
        let engine = ScriptEngine(source: """
        export function mediaPlaybackChanged(event) { throw new Error("펑"); }
        """)
        XCTAssertNil(engine.runLayerCallbacks(initial: LayerScriptState(alpha: 1, visible: true)))
    }

    /// 스크립트가 이상한 alpha를 넣어도 0~1로 죈다. 파일에서 온 코드다.
    func testAlphaIsClamped() throws {
        for (set, want) in [("-3", 0.0), ("42", 1.0)] {
            let engine = ScriptEngine(source: """
            export function mediaPlaybackChanged(e) { thisLayer.alpha = \(set); }
            """)
            let state = try XCTUnwrap(
                engine.runLayerCallbacks(initial: LayerScriptState(alpha: 1, visible: true)))
            XCTAssertEqual(state.alpha, want, accuracy: 0.001)
        }
    }
}

extension ScriptEngineTests {
    /// 실물 음악 위젯 진행 막대의 `visible` 스크립트를 줄인 것.
    /// 타이머가 끝나면 "재생 중인 음악이 없으니 숨어라"를 돌려준다.
    private var progressBarVisibleScript: String {
        """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'duration', value: 0.5, min: 0, max: 3 })
            .finish();
        let timer = scriptProperties.duration;
        let a = false;
        export function update(value) {
            if (timer > 0) { timer -= engine.frametime; return !a }
            else { value = a; return a }
        }
        """
    }

    /// 시간이 흐르면 스스로 숨어야 한다. 이걸 안 돌리면 저장된 `visible: true`로
    /// 그려져 배경화면 위에 흰 상자가 남는다(실물에서 확인).
    func testVisibleScriptHidesItselfOnceTimerExpires() throws {
        let engine = ScriptEngine(source: progressBarVisibleScript,
                                  properties: ["duration": 0.5])
        XCTAssertNil(engine.failure, "\(String(describing: engine.failure))")
        XCTAssertEqual(engine.update(value: true, frametime: 1.0), true,
                       "타이머가 도는 동안은 보인다")
        XCTAssertEqual(engine.update(value: true, frametime: 1.0), false,
                       "타이머가 끝나면 숨어야 한다")
    }

    /// 시간을 안 주면 타이머가 영영 안 끝난다. 프레임 간격이 아니라 진짜 경과
    /// 시간을 넘겨야 하는 이유가 이것이다.
    func testTimerDoesNotAdvanceWithoutElapsedTime() {
        let engine = ScriptEngine(source: progressBarVisibleScript,
                                  properties: ["duration": 0.5])
        for _ in 0..<20 {
            XCTAssertEqual(engine.update(value: true, frametime: 0), true)
        }
    }

    /// `engine` 전역이 없으면 `engine.frametime`이 예외를 던져 스크립트가 통째로
    /// 죽고, 레이어는 저장된 값으로 남는다.
    func testEngineGlobalExists() throws {
        let engine = ScriptEngine(source: """
        export function update(value) { return typeof engine.frametime; }
        """)
        XCTAssertEqual(engine.update(value: ""), "number")
    }

    /// alpha 스크립트는 실수를 돌려준다. 비유한값은 값을 안 바꾼다 —
    /// NaN 알파가 셰이더까지 흘러가면 레이어가 통째로 사라진다.
    func testAlphaScriptReturnsNumberAndRejectsNonFinite() {
        XCTAssertEqual(
            ScriptEngine(source: "export function update(v) { return 0.25; }")
                .update(value: 1.0, frametime: 0), 0.25)
        XCTAssertNil(
            ScriptEngine(source: "export function update(v) { return 0/0; }")
                .update(value: 1.0, frametime: 0))
        XCTAssertNil(
            ScriptEngine(source: "export function update(v) { return 'hi'; }")
                .update(value: 1.0, frametime: 0))
    }

    /// 빌더의 기본값을 본문 최상위에서 읽을 수 있어야 한다.
    /// 평가 뒤에 값을 넣으면 이 줄에는 이미 늦다.
    func testBuilderDefaultsAreReadableAtTopLevel() {
        let engine = ScriptEngine(source: """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'duration', value: 0.5 })
            .finish();
        let captured = scriptProperties.duration;
        export function update(value) { return String(captured); }
        """)
        XCTAssertEqual(engine.update(value: ""), "0.5")
    }

    /// 레이어 값이 빌더 기본값을 이긴다.
    func testLayerValueBeatsBuilderDefaultAtTopLevel() {
        let engine = ScriptEngine(
            source: """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: 'duration', value: 0.5 })
                .finish();
            let captured = scriptProperties.duration;
            export function update(value) { return String(captured); }
            """,
            properties: ["duration": 2])
        XCTAssertEqual(engine.update(value: ""), "2")
    }

    /// 레이어가 일부만 줘도 나머지 기본값이 남아야 한다.
    /// 통째로 갈아 끼우면 안 준 속성이 undefined가 된다.
    func testPartialLayerPropertiesKeepOtherDefaults() {
        let engine = ScriptEngine(
            source: """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: 'a', value: 1 })
                .addSlider({ name: 'b', value: 7 })
                .finish();
            export function update(value) {
                return scriptProperties.a + "," + scriptProperties.b;
            }
            """,
            properties: ["a": 9])
        XCTAssertEqual(engine.update(value: ""), "9,7")
    }
}
