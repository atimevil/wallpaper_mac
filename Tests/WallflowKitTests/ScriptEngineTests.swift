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
