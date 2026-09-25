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
    /// 지금까지 스크립트에 알려 준 누적 실행 시간(초). `engine.runtime`이 된다.
    private var runtime: Double = 0

    /// - Parameter modules: `import * as X from 'Y'`가 가리키는 모듈들(이름 → 본문).
    ///   실물에 `WEMath`·`WEColor`·`WEVector` 셋이 있고 전부 assets에 들어 있다.
    public init(source: String, properties: [String: Any] = [:],
                environment: SceneScriptRuntime.Environment = .init(),
                modules: [String: String] = [:]) {
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

        Self.installScriptPropertiesShim(context, layerProperties: properties)
        Self.installEngineShim(context, environment: environment)
        for statement in Self.moduleBindings(for: source, modules: modules) {
            context.evaluateScript(statement)
        }
        context.evaluateScript(Self.stripModuleSyntax(source))

        if let thrown {
            failure = .evaluationFailed(thrown)
            return
        }

        // 레이어가 준 값이 스크립트 안의 빌더를 이긴다. 빌더가 만든 객체에 **덮어쓴다** —
        // 통째로 갈아 끼우면 레이어가 안 준 속성의 기본값까지 같이 사라진다.
        if !properties.isEmpty {
            if let existing = context.objectForKeyedSubscript("scriptProperties"),
               existing.isObject {
                for (key, value) in properties {
                    existing.setObject(value, forKeyedSubscript: key as NSString)
                }
            } else {
                context.setObject(properties, forKeyedSubscript: "scriptProperties" as NSString)
            }
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

    /// 줄 맨 앞의 `export`, 그리고 `;`나 `}` 뒤 같은 줄에 이어지는 `export`를 지운다.
    /// ES 모듈 문법을 `evaluateScript`가 모르기 때문이다.
    /// 문자열 리터럴을 추적하는 규칙은 없다. 줄 맨 앞 규칙은 문자열이 줄 맨 앞에
    /// 오지 않으니 안전하지만, `;`/`}` 뒤 규칙은 `"...; export function..."`처럼
    /// 문자열 리터럴 안에서도 매치될 수 있다 — 드문 오탐으로 받아들인다.
    static func stripModuleSyntax(_ source: String) -> String {
        // `"\r\n"`은 Swift에서 **한 Character**라 `split(separator: "\n")`으로는 나뉘지 않는다.
        // 그러면 파일 전체가 한 줄이 되어 `export` 제거가 통째로 무력화된다 —
        // assets의 `wemath.js`가 CRLF라 실제로 이 일이 났다.
        source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line -> String in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            // `import * as shared from 'shared.js'` 같은 줄이 있다. 모듈을 풀어 줄
            // 방법이 없으므로 줄을 지운다 — 남겨 두면 `evaluateScript`가 구문 오류로
            // **스크립트 전체**를 버려서, 모듈을 실제로 쓰지 않는 부분까지 죽는다.
            // 실물에서 이 한 줄 때문에 스크립트 4개가 통째로 떨어졌다.
            if trimmed.hasPrefix("import ") { return "" }
            guard trimmed.hasPrefix("export ") else { return stripMidLineExport(String(line)) }
            let indent = String(line.prefix(line.count - trimmed.count))
            return indent + stripMidLineExport(String(trimmed.dropFirst("export ".count)))
        }.joined(separator: "\n")
    }

    /// `let done = false; export function update(v) { ... }`처럼 앞 문장과 `export`가
    /// 세미콜론으로 한 줄에 묶이면 줄 맨 앞 규칙이 못 잡는다. JavaScriptCore가
    /// SyntaxError를 던지고 유닛이 조용히 등록 실패한다 — 겉보기엔 스크립트가
    /// 아무 일도 안 한 것처럼 보인다.
    /// `;`나 `}` 바로 뒤(공백 허용)에서 함수/클래스/변수 선언을 여는 `export`만
    /// 지운다. 뒤따르는 단어의 경계까지 봐서 `export functionCall()`처럼 선언이
    /// 아닌 자리는 건드리지 않는다.
    static func stripMidLineExport(_ line: String) -> String {
        let declarationKeywords = ["function", "class", "let", "var", "const", "default"]
        var result = ""
        var rest = Substring(line)
        while let exportRange = rest.range(of: "export ") {
            let before = rest[rest.startIndex..<exportRange.lowerBound]
            let after = rest[exportRange.upperBound...]
            let precededByStatementEnd = before.reversed()
                .first(where: { $0 != " " && $0 != "\t" })
                .map { $0 == ";" || $0 == "}" } ?? false
            let opensDeclaration = declarationKeywords.contains { keyword in
                guard after.hasPrefix(keyword) else { return false }
                let next = after[after.index(after.startIndex, offsetBy: keyword.count)...].first
                return !(next.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false)
            }
            result += before
            result += (precededByStatementEnd && opensDeclaration) ? "" : "export "
            rest = after
        }
        result += rest
        return result
    }

    /// `import * as X from 'Y'` 한 줄마다, 모듈 본문을 즉시실행 함수로 감싸
    /// `var X = (function () { ... return {내보낸 이름들}; })();`를 만든다.
    ///
    /// JavaScriptCore의 `evaluateScript`는 ES 모듈을 모른다. 모듈을 안 주면
    /// `WEMath.smoothStep(...)`이 참조 오류를 내고 스크립트가 죽는다.
    /// 모르는 모듈은 건너뛴다 — 못 채우는 이름을 빈 객체로 채우면 오류가
    /// "없는 변수"에서 "함수가 아닌 값"으로 바뀔 뿐이다.
    static func moduleBindings(for source: String, modules: [String: String]) -> [String] {
        guard !modules.isEmpty else { return [] }
        // 이름은 대소문자가 파일과 다르다(`WEMath` ↔ `wemath.js`).
        var byLowercasedName: [String: String] = [:]
        for (name, body) in modules { byLowercasedName[name.lowercased()] = body }

        var statements: [String] = []
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            guard let alias = trimmed.components(separatedBy: " as ").dropFirst().first?
                .components(separatedBy: " from ").first?
                .trimmingCharacters(in: .whitespaces),
                !alias.isEmpty, alias.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { continue }
            let quoted = trimmed.split(separator: "'").dropFirst().first
                ?? trimmed.split(separator: "\"").dropFirst().first
            guard let quoted, let body = byLowercasedName[String(quoted).lowercased()]
            else { continue }
            let exported = exportedNames(in: body)
            guard !exported.isEmpty else { continue }
            let members = exported.map { "\($0): \($0)" }.joined(separator: ", ")
            statements.append("""
            var \(alias) = (function () {
            \(stripModuleSyntax(body))
            return { \(members) };
            })();
            """)
        }
        return statements
    }

    /// 모듈이 내보내는 이름들. `export let x`, `export function f`, `export var v` 형태다.
    static func exportedNames(in source: String) -> [String] {
        var names: [String] = []
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export ") else { continue }
            var rest = trimmed.dropFirst("export ".count)
            for keyword in ["let ", "var ", "const ", "function ", "class "]
            where rest.hasPrefix(keyword) {
                rest = rest.dropFirst(keyword.count)
                break
            }
            let name = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// `createScriptProperties()`는 편집기 UI를 정의하는 빌더다. 값은 레이어가 준다.
    /// 무엇을 부르든 자기 자신을 돌려주기만 하면 스크립트가 끝까지 평가된다.
    /// `update(value)`를 불리언으로 부른다. `visible` 속성에 붙은 스크립트용이다.
    ///
    /// 실물 음악 위젯의 진행 막대는 이렇게 스스로 숨는다:
    /// ```js
    /// let timer = scriptProperties.duration;  // 0.5초
    /// let a = false;                          // 썸네일이 생기면 true가 된다
    /// export function update(value) {
    ///     if (timer > 0) { timer -= engine.frametime; return !a }
    ///     else { return a }
    /// }
    /// ```
    /// 시간이 지나면 `false`를 돌려준다 — 재생 중인 음악이 없으니 숨으라는 뜻이다.
    /// 이걸 안 돌리면 저장된 `visible: true`로 그려져 흰 상자가 화면에 남는다.
    ///
    /// - Parameter frametime: 지난 호출 이후 실제로 흐른 시간(초).
    ///   스크립트를 매 프레임이 아니라 1초에 한 번 돌리므로, 프레임 간격이 아니라
    ///   진짜 경과 시간을 줘야 시간 기반 로직이 맞게 흐른다.
    public func update(value: Bool, frametime: Double) -> Bool? {
        guard let result = callUpdate(value, frametime: frametime) else { return nil }
        return result.toBool()
    }

    /// `update(value)`를 실수로 부른다. `alpha` 속성에 붙은 스크립트용이다.
    public func update(value: Double, frametime: Double) -> Double? {
        guard let result = callUpdate(value, frametime: frametime),
              result.isNumber, result.toDouble().isFinite else { return nil }
        return result.toDouble()
    }

    private func callUpdate(_ value: Any, frametime: Double) -> JSValue? {
        guard let updateFunction else { return nil }
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "알 수 없는 예외"
        }
        // 시간이 흘렀다고 스크립트에 알린다. 없으면 `engine.frametime`이 undefined라
        // 뺄셈이 NaN이 되고 타이머가 영영 안 끝난다.
        runtime += Swift.max(0, frametime)
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            engine.setObject(frametime, forKeyedSubscript: "frametime" as NSString)
            engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
        }
        let result = updateFunction.call(withArguments: [value])
        if let thrown {
            failure = .updateFailed(thrown)
            return nil
        }
        guard let result, !result.isUndefined, !result.isNull else { return nil }
        failure = nil
        return result
    }

    /// 스크립트가 있다고 가정하는 전역들(`Vec3`, `engine`, `console`).
    /// 없으면 참조하는 스크립트가 통째로 죽는다 — 실물 145개 중 대부분이 쓴다.
    /// `frametime`/`runtime`은 매 호출마다 `callUpdate`가 채운다.
    private static func installEngineShim(_ context: JSContext,
                                          environment: SceneScriptRuntime.Environment) {
        context.evaluateScript(SceneScriptRuntime.vectors)
        context.evaluateScript(SceneScriptRuntime.engine(environment))
    }

    /// `createScriptProperties()` 흉내.
    ///
    /// 빌더는 편집기 UI 정의지만 **기본값도 함께 들고 있다**(`{name, value}`).
    /// 그 기본값을 빌더 객체에 얹어야 스크립트가 본문 최상위에서 읽을 수 있다:
    /// ```js
    /// let timer = scriptProperties.duration;   // ← 여기서 이미 읽는다
    /// export function update(value) { ... }
    /// ```
    /// 평가가 끝난 뒤에 값을 넣어 주면 이 줄에는 이미 늦었다 — `timer`가 undefined가
    /// 되어 `timer > 0`이 처음부터 거짓이 되고, 진행 막대가 숨어야 할 때를 스스로
    /// 못 정한다. 레이어가 준 값은 여기서 기본값을 이긴다.
    private static func installScriptPropertiesShim(
        _ context: JSContext, layerProperties: [String: Any]
    ) {
        context.setObject(layerProperties,
                          forKeyedSubscript: "__wallflowLayerProperties" as NSString)
        context.evaluateScript("""
        function createScriptProperties() {
            var layer = __wallflowLayerProperties || {};
            var builder = {};
            // `add*`는 이름을 열거하지 않는다. 실물에 `addColor`가 있었는데 목록에
            // 없어서 스크립트가 통째로 죽었다 — 모르는 이름이 하나 더 있으면 같은 일이
            // 또 난다. add로 시작하면 무엇이든 받고, 체인이 끊기지 않게 프록시를 돌려준다.
            var proxy = new Proxy(builder, {
                get: function (target, name) {
                    if (name in target) { return target[name]; }
                    if (typeof name === 'string' && name.indexOf('add') === 0) {
                        return handler;
                    }
                    return undefined;
                }
            });
            var handler = function (spec) {
                if (spec && spec.name !== undefined && spec.name !== null) {
                    builder[spec.name] = Object.prototype.hasOwnProperty.call(layer, spec.name)
                        ? layer[spec.name] : spec.value;
                }
                return proxy;
            };
            // `.finish()`를 부르지 않는 스크립트가 있어서 빌더 자체가 값 노릇을 한다.
            builder.finish = function () { return proxy; };
            return proxy;
        }
        """)
    }

}
