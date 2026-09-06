import Foundation
import JavaScriptCore

/// 스크립트가 값을 만들지 못한 이유. 배경화면이 조용히 비는 것을 막으려고 남긴다.
public enum ScriptFailure: Equatable, Sendable {
    /// 스크립트 본문을 평가하다 예외가 났다.
    case evaluationFailed(String)
    /// `update` 함수가 없다. 스크립트가 아니거나 우리가 모르는 모양이다.
    case noUpdateFunction
    /// `update`를 부르다 예외가 났다.
    case updateFailed(String)
    /// 아직 돌고 있어 새 값이 없다. 호출자가 이전 값을 유지한다.
    case stillRunning
}

/// 창작마당 `.pkg`에 든 레이어 스크립트를 돌린다.
///
/// 스크립트는 **임의의 제3자가 올린 코드**다. 그리고 이 앱은 배경화면이라 항상 켜져
/// 있다. 거대한 문자열 하나가 메모리를 삼키지 못하도록 길이를 죈다.
///
/// **시간은 여기서 죄지 못한다.** 실행 중인 자바스크립트를 중단시키는
/// `JSContextGroupSetExecutionTimeLimit`은 Apple 플랫폼에서 비공개 API라 쓸 수 없다.
/// 그래서 `while(true){}` 한 줄을 끊을 방법이 없다. 대신 호출자가 이 엔진을 레이어마다
/// 하나씩 **직렬 큐에 가두어 비동기로** 부른다. 그러면 폭주하는 스크립트가 코어 하나를
/// 태우더라도 화면은 계속 돌고, 그 레이어의 값만 마지막 상태로 멈춘다
/// (`SceneRenderer` 참고). 렌더 스레드에서 직접 부르지 마라.
///
/// `JSContext`는 스레드 안전하지 않다. 인스턴스 하나를 한 스레드에서만 쓴다.
/// 레이어 속성 스크립트가 정하는 표시 상태.
public struct LayerScriptState: Equatable, Sendable {
    public var alpha: Double
    public var visible: Bool

    public init(alpha: Double, visible: Bool) {
        self.alpha = alpha
        self.visible = visible
    }
}

/// 직렬 큐 하나에 갇혀 쓰이는 것을 전제로 Sendable을 단다. `JSContext`는 스레드
/// 안전하지 않으므로 두 스레드에서 동시에 부르면 안 된다. 이 약속은 호출자가 지킨다.
public final class ScriptEngine: @unchecked Sendable {
    /// 돌려받는 문자열의 상한. 글자 하나하나가 텍스처가 되므로 길이가 곧 메모리다.
    /// 실물 시계는 열 글자 안쪽이다.
    public static let maxResultLength = 4096

    private let context: JSContext
    private var updateFunction: JSValue?

    /// 스크립트를 올린다. 실패해도 던지지 않는다 — 레이어 하나가 못 그려질 뿐,
    /// 씬 전체가 죽으면 안 된다. 이유는 `failure`로 확인한다.
    public private(set) var failure: ScriptFailure?

    /// - Parameters:
    ///   - source: 스크립트 본문.
    ///   - properties: 레이어의 `scriptproperties`. 스크립트 안의
    ///     `createScriptProperties()` 빌더를 **덮어쓴다** — 빌더는 편집기 UI 정의라
    ///     실제 값이 아니다. 덮어쓰지 않으면 `scriptProperties.delimiter`가
    ///     undefined가 되어 시계가 `12undefined34`처럼 나온다.
    public init(source: String, properties: [String: Any] = [:]) {
        guard let context = JSContext() else {
            self.context = JSContext(virtualMachine: JSVirtualMachine())!
            failure = .evaluationFailed("JSContext를 만들 수 없다")
            return
        }
        self.context = context

        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "알 수 없는 예외"
        }

        Self.installScriptPropertiesShim(context)
        context.evaluateScript(Self.stripModuleSyntax(source))

        if let thrown {
            failure = .evaluationFailed(thrown)
            return
        }

        // 레이어가 준 값이 스크립트 안의 빌더를 이긴다.
        if !properties.isEmpty {
            context.setObject(properties, forKeyedSubscript: "scriptProperties" as NSString)
        }

        guard let update = context.objectForKeyedSubscript("update"),
              !update.isUndefined, !update.isNull else {
            failure = .noUpdateFunction
            return
        }
        updateFunction = update
    }

    /// `update(value)`를 부른다. 실패하면 nil을 돌려주고 호출자가 이전 값을 유지한다.
    /// 값을 못 바꾸는 것보다 잘못된 값을 쓰는 게 나쁘다.
    public func update(value: String) -> String? {
        guard let updateFunction else { return nil }

        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "알 수 없는 예외"
        }

        let result = updateFunction.call(withArguments: [value])

        if let thrown {
            failure = .updateFailed(thrown)
            return nil
        }
        guard let result, !result.isUndefined, !result.isNull else { return nil }

        let text = result.toString() ?? ""
        failure = nil
        // 길이는 곧 메모리다. 자를 때 UTF-16 경계를 넘지 않게 문자 단위로 센다.
        return text.count > Self.maxResultLength
            ? String(text.prefix(Self.maxResultLength)) : text
    }

    /// 레이어 속성 스크립트를 돌려 최종 표시 상태를 얻는다.
    ///
    /// 창작마당의 미디어 위젯(앨범 표지·곡 제목)은 `update`가 아니라 **이벤트 콜백**으로
    /// 자기를 숨긴다. 실물 스크립트가 이렇게 되어 있다:
    /// ```js
    /// let isPlaying = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
    /// thisLayer.alpha = isPlaying ? 1 : 0;
    /// ```
    /// 즉 **음악이 안 나오면 숨긴다.** 이벤트를 안 보내면 저장된 alpha(0.5)로 그려져
    /// 배경화면 위에 반투명한 검은 상자가 남는다. 추측해서 숨기는 대신 스크립트에게
    /// "지금 아무것도 재생 중이 아니다"라고 알려 스스로 판단하게 한다.
    ///
    /// - Returns: 스크립트가 정한 표시 상태. 콜백이 하나도 없으면 nil.
    public func runLayerCallbacks(initial: LayerScriptState) -> LayerScriptState? {
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "알 수 없는 예외"
        }

        context.setObject(
            ["alpha": initial.alpha, "visible": initial.visible, "isUserHidden": false],
            forKeyedSubscript: "thisLayer" as NSString)
        // 실물 스크립트가 쓰는 상수와 API를 흉내 낸다. 값 자체는 중요하지 않고
        // 같은 상수끼리 비교되기만 하면 된다.
        context.evaluateScript("""
        var MediaPlaybackEvent = { PLAYBACK_PLAYING: 0, PLAYBACK_PAUSED: 1, PLAYBACK_STOPPED: 2 };
        var MediaThumbnailEvent = {};
        // 애니메이션 API는 없다. 불려도 죽지 않게만 한다.
        var thisObject = { getAnimation: function () { return { play: function () {} }; } };
        """)

        var ran = false
        // init은 사용자가 저장한 값을 받는다. 이걸 건너뛰면 isUserHidden이 정해지지 않는다.
        if let initFn = context.objectForKeyedSubscript("init"), !initFn.isUndefined {
            initFn.call(withArguments: [initial.visible])
            ran = true
        }
        // 지금 아무것도 재생 중이 아니다. 그게 사실이다.
        if let fn = context.objectForKeyedSubscript("mediaPlaybackChanged"), !fn.isUndefined {
            fn.call(withArguments: [["state": 2]])
            ran = true
        }
        if let fn = context.objectForKeyedSubscript("mediaThumbnailChanged"), !fn.isUndefined {
            fn.call(withArguments: [["hasThumbnail": false]])
            ran = true
        }
        guard ran else { return nil }
        if let thrown {
            failure = .updateFailed(thrown)
            return nil
        }

        guard let layer = context.objectForKeyedSubscript("thisLayer"), !layer.isUndefined,
              let alpha = layer.objectForKeyedSubscript("alpha")?.toDouble(),
              alpha.isFinite else { return nil }
        let visible = layer.objectForKeyedSubscript("visible")?.toBool() ?? initial.visible
        return LayerScriptState(alpha: min(max(alpha, 0), 1), visible: visible)
    }

    /// 줄 맨 앞의 `export`만 지운다. ES 모듈 문법을 `evaluateScript`가 모르기 때문이다.
    /// 문자열 리터럴 안의 "export"는 줄 맨 앞에 오지 않으므로 건드리지 않는다.
    static func stripModuleSyntax(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("export ") else { return String(line) }
            let indent = String(line.prefix(line.count - trimmed.count))
            return indent + String(trimmed.dropFirst("export ".count))
        }.joined(separator: "\n")
    }

    /// `createScriptProperties()`는 편집기 UI를 정의하는 빌더다. 값은 레이어가 준다.
    /// 무엇을 부르든 자기 자신을 돌려주기만 하면 스크립트가 끝까지 평가된다.
    private static func installScriptPropertiesShim(_ context: JSContext) {
        context.evaluateScript("""
        function createScriptProperties() {
            var builder = {};
            var handler = function () { return builder; };
            var names = ['addCheckbox', 'addSlider', 'addTextInput', 'addCombo',
                         'addColorPicker', 'addFilePicker', 'addText', 'addSeparator',
                         'addSpinner', 'addVec2', 'addVec3', 'finish'];
            for (var i = 0; i < names.length; i++) { builder[names[i]] = handler; }
            return builder;
        }
        """)
    }

}
