import Foundation
import JavaScriptCore

/// 씬 하나의 스크립트 전부를 **한 컨텍스트**에서 돌린다.
///
/// 레이어마다 컨텍스트를 따로 두면 실물 씬이 깨진다. 실물 원근 씬은 행렬 라이브러리를
/// 한 레이어의 스크립트가 `shared.Mat4 = …`로 올려 두고 다른 레이어들이 가져다 쓰며,
/// 프리즘 스크립트가 `thisScene.createLayer(asset)`으로 메시 11쌍을 만들고
/// 카메라 스크립트가 `thisScene.setCameraTransforms`로 눈을 옮긴다. 이런 것은
/// 모두 **씬 하나의 상태**라 컨텍스트가 하나여야 한다.
///
/// 스크립트 하나하나는 즉시실행 함수로 감싸 **자기 지역 범위**를 갖는다. 그래서
/// 스크립트마다 `update`·`init`을 따로 정의해도 서로 덮어쓰지 않고, 서로 볼 수
/// 있는 것은 `shared`·`thisScene`·`engine`뿐이다 — 실물 SceneScript와 같은 모양이다.
///
/// 이름과 의미는 공식 레퍼런스를 따랐다:
/// <https://docs.wallpaperengine.io/en/scene/scenescript/reference.html>
/// (IScene: getLayer·createLayer·get/setCameraTransforms, ILayer: origin·angles·
/// scale·visible·name·parallaxDepth, IEngine: registerAsset·frametime·runtime).
/// `alpha`·`color`는 레퍼런스에 없지만 실물 스크립트가 쓰므로 둔다.
///
/// **시간은 죄지 못한다.** `ScriptEngine`과 같은 이유로(비공개 API) 무한 루프를
/// 끊을 수 없다. 호출자가 이 호스트를 직렬 큐 하나에 가둬 비동기로 부른다 —
/// 폭주하면 그 씬의 스크립트만 마지막 값에서 멈추고 화면은 계속 돈다.
/// `JSContext`는 스레드 안전하지 않다. 한 스레드에서만 쓴다.
public final class SceneScriptHost: @unchecked Sendable {
    /// 스크립트가 만들 수 있는 레이어 수의 상한. 스크립트는 창작마당 코드라
    /// 매 프레임 `createLayer`를 부를 수도 있다. 넘치면 화면에 안 붙는 빈 객체를 준다 —
    /// null을 주면 `.name =`에서 스크립트가 죽는다. 실물 최대는 프리즘 22 + 오브 7 + 소리 5다.
    public static let maxSpawnedLayers = 256
    /// 돌려받는 글자의 상한. `ScriptEngine.maxResultLength`와 같은 이유다.
    public static let maxTextLength = 4096
    /// 같은 스크립트가 연달아 이만큼 예외를 내면 더 부르지 않는다.
    static let maxConsecutiveFailures = 3

    /// 재질 상수 하나에 붙은 스크립트. `thisObject`가 그 재질의 상수 묶음이다.
    ///
    /// 실물 프리즘 재질의 `Alpha`가 `shared.fade`를 따라 서서히 나타나고, `Light`가
    /// 분침이며, 색은 `applyUserProperties`에서 `thisObject.start_color = …`로 온다.
    public struct MaterialScript: Equatable, Sendable {
        public let key: String
        public let source: String
        /// 시작값. 수 하나이거나 벡터다.
        public let value: EffectConstant?

        public init(key: String, source: String, value: EffectConstant?) {
            self.key = key
            self.source = source
            self.value = value
        }
    }

    /// 레이어 하나의 시작 상태. 스크립트가 읽고 고치는 값들이다.
    public struct LayerSeed: Equatable, Sendable {
        public var id: Int
        public var name: String
        public var origin: Vec3
        public var angles: Vec3
        public var scale: Vec3
        public var alpha: Double
        public var visible: Bool
        public var color: Vec3
        public var size: Vec2
        public var text: String?
        /// 소리 레이어면 지금 나는지. 아니면 nil.
        public var playing: Bool?
        public var volume: Double?
        public var scripts: [LayerScript]
        /// 이 레이어의 재질 상수 스크립트. 렌더러가 재질을 열어 본 뒤 채운다.
        public var materialScripts: [MaterialScript] = []
        /// 글자 레이어의 글자 크기(씬 단위). `thisObject.pointsize`로 스크립트가 바꾼다.
        public var pointSize: Double?
        /// 부모 레이어 id. `thisLayer.getChildren()`이 이걸로 자식을 찾는다.
        public var parent: Int?

        public init(id: Int, name: String, origin: Vec3, angles: Vec3, scale: Vec3,
                    alpha: Double, visible: Bool, color: Vec3 = Vec3(x: 1, y: 1, z: 1),
                    size: Vec2 = Vec2(x: 0, y: 0), text: String? = nil,
                    playing: Bool? = nil, volume: Double? = nil,
                    scripts: [LayerScript] = []) {
            self.id = id
            self.name = name
            self.origin = origin
            self.angles = angles
            self.scale = scale
            self.alpha = alpha
            self.visible = visible
            self.color = color
            self.size = size
            self.text = text
            self.playing = playing
            self.volume = volume
            self.scripts = scripts
        }

        public init(_ layer: SceneLayer) {
            var text: String?
            var playing: Bool?
            var volume: Double?
            var pointSize: Double?
            switch layer.content {
            case .text(let t):
                text = t.value
                pointSize = t.wrapping.pointSize > 0 ? t.wrapping.pointSize : nil
            case .sound(let s):
                playing = !s.startsSilent
                volume = s.volume
            case .particle:
                // 파티클도 `play()/stop()`의 대상이다. 처음에는 돈다.
                playing = true
            default: break
            }
            // 보임은 자체 값이다. 부모까지 합친 값은 렌더러가 조상 사슬로 다시 만든다 —
            // 스크립트가 부모를 숨기면 자식도 같이 숨어야 한다.
            self.init(id: layer.id, name: layer.name, origin: layer.localOrigin,
                      angles: layer.angles, scale: layer.localScale, alpha: layer.alpha,
                      visible: layer.localVisible, color: layer.tint, size: layer.size,
                      text: text, playing: playing, volume: volume, scripts: layer.scripts)
            self.pointSize = pointSize
            self.parent = layer.parentID
        }
    }

    /// 한 틱이 끝난 뒤의 레이어 상태.
    public struct LayerState: Equatable, Sendable {
        public var name: String
        public var origin: Vec3
        public var angles: Vec3
        public var scale: Vec3
        public var alpha: Double
        public var visible: Bool
        public var color: Vec3
        public var size: Vec2
        public var text: String?
        public var playing: Bool?
        public var volume: Double?
        /// 스크립트가 만든 레이어면 그 자산 경로.
        public var asset: String?
        /// 재질 상수 스크립트가 정한 값들. 키는 재질의 `constantshadervalues` 키다.
        public var material: [String: EffectConstant] = [:]
        /// 글자 크기(씬 단위). 글자 레이어가 아니면 nil.
        public var pointSize: Double?
    }

    public struct Snapshot: Equatable, Sendable {
        /// 레이어 id → 상태. 스크립트가 만든 레이어는 음수 id다.
        public var layers: [Int: LayerState]
        /// 만들어진 순서. 스크립트가 만든 레이어는 문서 레이어 뒤에 온다.
        public var order: [Int]
        /// 스크립트가 카메라를 옮겼으면 그 값. 아니면 nil.
        public var camera: SceneCamera?
        /// 이번 틱에 새로 난 스크립트 오류. 같은 스크립트는 몇 번 뒤 조용해진다.
        public var failures: [String]

        public static let empty = Snapshot(layers: [:], order: [], camera: nil, failures: [])
    }

    private let context: JSContext
    private var runtime: Double = 0
    private var camera: SceneCamera?
    /// 호스트 자체를 만들지 못한 이유. 스크립트 하나의 오류는 여기 오지 않는다.
    public private(set) var fatalFailure: String?
    /// 컨텍스트에 실린 스크립트 수. 0이면 돌릴 것이 없다.
    public private(set) var unitCount = 0

    /// - Parameters:
    ///   - layers: 문서 순서대로의 레이어들. **숨은 것도 넣어야 한다.**
    ///   - userProperties: `applyUserProperties`에 넘길 값. 색은 Vec3가 된다.
    public init(layers: [LayerSeed], camera: SceneCamera?,
                environment: SceneScriptRuntime.Environment = .init(),
                modules: [String: String] = [:],
                userProperties: [String: UserPropertyValue] = [:]) {
        self.camera = camera
        self.modules = modules
        self.userPropertiesJSON = Self.userPropertiesJSON(userProperties)
        guard let context = JSContext() else {
            self.context = JSContext(virtualMachine: JSVirtualMachine())!
            fatalFailure = "JSContext를 만들 수 없다"
            return
        }
        self.context = context
        // 핸들러는 인스턴스 변수에 쓴다. 지역 변수를 inout으로 넘기면서 동시에
        // 핸들러가 쓰면 Swift 배타 접근 위반으로 죽는다.
        context.exceptionHandler = { [weak self] _, value in
            self?.lastThrown = value?.toString() ?? "알 수 없는 예외"
        }
        context.evaluateScript(SceneScriptRuntime.vectors)
        context.evaluateScript(SceneScriptRuntime.engine(environment))
        context.evaluateScript(Self.prelude)
        if let thrown = lastThrown {
            fatalFailure = "런타임을 올리지 못했다: \(thrown)"
            return
        }

        let cameraJSON = camera.map(Self.cameraJSON) ?? "null"
        context.evaluateScript("__wfSetCamera(\(cameraJSON));")
        for seed in layers {
            context.evaluateScript("__wfAddLayer(\(Self.seedJSON(seed)));")
        }
        for seed in layers {
            for script in seed.scripts {
                register(Self.unitSource(layerID: seed.id, script: script, modules: modules),
                         name: "\(seed.name).\(script.property)")
            }
            for script in seed.materialScripts {
                register(Self.materialUnitSource(layerID: seed.id, script: script, modules: modules),
                         name: "\(seed.name).\(script.key)")
            }
        }
        unitCount = Int(context.evaluateScript("__wf.units.length")?.toInt32() ?? 0)
        context.evaluateScript("__wfRunInit(\(userPropertiesJSON), 0);")
        wantsAudio = (context.evaluateScript("__wf.audio.length")?.toInt32() ?? 0) > 0
    }

    private let modules: [String: String]
    private let userPropertiesJSON: String
    /// 마지막으로 컨텍스트가 던진 예외. 등록 직후 읽고 비운다.
    private var lastThrown: String?

    private func register(_ source: String, name: String) {
        lastThrown = nil
        context.evaluateScript(source)
        // 실패한 스크립트는 등록 자체가 안 된다. 이유만 남긴다.
        if let reason = lastThrown {
            lastThrown = nil
            context.evaluateScript("__wf.failures.push(\(Self.jsString("\(name): \(reason)")));")
        }
    }

    /// 스크립트가 만든 레이어의 재질 상수 스크립트를 뒤늦게 붙인다.
    ///
    /// `createLayer`로 만든 프리즘도 재질에 `Alpha`·색 스크립트가 있다. 렌더러가
    /// 그 레이어를 세운 뒤에야 재질을 알므로 여기서 붙이고, 새 스크립트들만
    /// init·applyUserProperties를 바로 돌린다.
    public func attachMaterialScripts(layerID: Int, _ scripts: [MaterialScript]) {
        guard fatalFailure == nil, !scripts.isEmpty else { return }
        let before = Int(context.evaluateScript("__wf.units.length")?.toInt32() ?? 0)
        for script in scripts {
            register(Self.materialUnitSource(layerID: layerID, script: script, modules: modules),
                     name: "layer \(layerID).\(script.key)")
        }
        unitCount = Int(context.evaluateScript("__wf.units.length")?.toInt32() ?? 0)
        context.evaluateScript("__wfRunInit(\(userPropertiesJSON), \(before));")
    }

    /// 한 틱. `update(value)`를 모두 부르고 상태를 읽는다.
    ///
    /// - Parameter frametime: 지난 틱 이후 흐른 시간(초). `engine.frametime`이 된다.
    /// 스크립트가 `engine.registerAudioBuffers`로 오디오를 달라고 했는지.
    /// 그때만 호출자가 `tick`에 스펙트럼을 넘긴다 — 안 쓰는 씬에 매 틱 보내는 것은 낭비다.
    public private(set) var wantsAudio = false

    /// - Parameter audio: 해상도별 좌·우 스펙트럼(0~1). `wantsAudio`일 때만 의미 있다.
    ///   소리를 듣지 않는 중이면 빈 사전을 준다 — 버퍼는 0으로 남는다.
    public func tick(frametime: Double, cursorWorld: Vec3? = nil,
                     cursorScreen: Vec2? = nil,
                     audio: [Int: (left: [Float], right: [Float])] = [:]) -> Snapshot {
        guard fatalFailure == nil else { return .empty }
        let dt = frametime.isFinite ? Swift.max(0, frametime) : 0
        runtime += dt
        let cw = cursorWorld ?? Vec3(x: 0, y: 0, z: 0)
        let cs = cursorScreen ?? Vec2(x: 0, y: 0)
        let audioJSON = wantsAudio && !audio.isEmpty ? Self.audioJSON(audio) : "null"
        let call = "__wfTick(\(dt), \(runtime), \(cw.x), \(cw.y), \(cw.z), \(cs.x), \(cs.y), \(audioJSON))"
        guard let json = context.evaluateScript(call)?.toString(),
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .empty }
        return parse(root)
    }

    // MARK: - 결과 읽기

    private func parse(_ root: [String: Any]) -> Snapshot {
        var layers: [Int: LayerState] = [:]
        var order: [Int] = []
        for case let raw as [String: Any] in (root["layers"] as? [Any] ?? []) {
            guard let id = (raw["id"] as? NSNumber)?.intValue else { continue }
            var state = LayerState(
                name: String((raw["name"] as? String ?? "").prefix(256)),
                origin: Self.vec3(raw["o"]) ?? Vec3(x: 0, y: 0, z: 0),
                angles: Self.vec3(raw["a"]) ?? Vec3(x: 0, y: 0, z: 0),
                scale: Self.vec3(raw["s"]) ?? Vec3(x: 1, y: 1, z: 1),
                alpha: Swift.min(Swift.max(Self.number(raw["al"]) ?? 1, 0), 1),
                visible: (raw["v"] as? NSNumber)?.boolValue ?? true,
                color: Self.vec3(raw["c"]) ?? Vec3(x: 1, y: 1, z: 1),
                size: Self.vec2(raw["sz"]) ?? Vec2(x: 0, y: 0),
                text: (raw["t"] as? String).map { String($0.prefix(Self.maxTextLength)) },
                playing: raw["p"] as? Bool,
                volume: Self.number(raw["vol"]).map { Swift.min(Swift.max($0, 0), 1) },
                asset: raw["asset"] as? String)
            var material: [String: EffectConstant] = [:]
            for (key, value) in (raw["m"] as? [String: Any] ?? [:]) {
                if let d = Self.number(value) { material[key] = .scalar(d) }
                else if let v = Self.vec3(value) { material[key] = .vector([v.x, v.y, v.z]) }
            }
            state.material = material
            state.pointSize = Self.number(raw["pt"]).map { Swift.max($0, 0) }
            layers[id] = state
            order.append(id)
        }
        var cameraOut: SceneCamera?
        if let raw = root["camera"] as? [String: Any], var camera {
            if let eye = Self.vec3(raw["eye"]) { camera.eye = eye }
            if let center = Self.vec3(raw["center"]) { camera.center = center }
            if let up = Self.vec3(raw["up"]) { camera.up = up }
            self.camera = camera
            cameraOut = camera
        }
        let failures = (root["failures"] as? [Any] ?? []).compactMap { $0 as? String }
        wantsAudio = ((root["audio"] as? NSNumber)?.intValue ?? 0) > 0
        return Snapshot(layers: layers, order: order, camera: cameraOut, failures: failures)
    }

    /// `{"16": {"l": [...], "r": [...]}, ...}`. 값은 유한한 0~1로 죈다.
    static func audioJSON(_ audio: [Int: (left: [Float], right: [Float])]) -> String {
        var object: [String: Any] = [:]
        for (resolution, bands) in audio where resolution > 0 && resolution <= 256 {
            func clean(_ values: [Float]) -> [Double] {
                values.prefix(resolution).map { $0.isFinite ? Double(Swift.min(Swift.max($0, 0), 1)) : 0 }
            }
            object[String(resolution)] = ["l": clean(bands.left), "r": clean(bands.right)]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON의 수. `true`/`false`도 NSNumber로 오므로 타입으로 가른다 —
    /// `is Bool`로 거르면 0과 1이 불리언으로 읽혀 좌표 0이 통째로 사라진다.
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func vec3(_ raw: Any?) -> Vec3? {
        guard let parts = raw as? [Any], parts.count >= 3,
              let x = number(parts[0]), let y = number(parts[1]), let z = number(parts[2])
        else { return nil }
        return Vec3(x: x, y: y, z: z)
    }

    private static func vec2(_ raw: Any?) -> Vec2? {
        guard let parts = raw as? [Any], parts.count >= 2,
              let x = number(parts[0]), let y = number(parts[1]) else { return nil }
        return Vec2(x: x, y: y)
    }

    // MARK: - 자바스크립트 만들기

    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func finite(_ d: Double) -> Double { d.isFinite ? d : 0 }

    private static func vecJSON(_ v: Vec3) -> String {
        "[\(finite(v.x)),\(finite(v.y)),\(finite(v.z))]"
    }

    static func seedJSON(_ seed: LayerSeed) -> String {
        var fields = [
            "id": "\(seed.id)",
            "name": jsString(seed.name),
            "o": vecJSON(seed.origin),
            "a": vecJSON(seed.angles),
            "s": vecJSON(seed.scale),
            "al": "\(finite(seed.alpha))",
            "v": seed.visible ? "true" : "false",
            "c": vecJSON(seed.color),
            "sz": "[\(finite(seed.size.x)),\(finite(seed.size.y))]",
        ]
        if let text = seed.text { fields["t"] = jsString(text) }
        if let playing = seed.playing { fields["p"] = playing ? "true" : "false" }
        if let volume = seed.volume { fields["vol"] = "\(finite(volume))" }
        if let pointSize = seed.pointSize { fields["pt"] = "\(finite(pointSize))" }
        if let parent = seed.parent { fields["parent"] = "\(parent)" }
        return "{" + fields.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "}"
    }

    static func cameraJSON(_ camera: SceneCamera) -> String {
        "{\"eye\": \(vecJSON(camera.eye)), \"center\": \(vecJSON(camera.center)), "
            + "\"up\": \(vecJSON(camera.up)), \"fov\": \(finite(camera.fov))}"
    }

    static func userPropertiesJSON(_ values: [String: UserPropertyValue]) -> String {
        var object: [String: Any] = [:]
        for (name, value) in values {
            switch value {
            case .toggle(let b): object[name] = b
            case .number(let d): object[name] = d.isFinite ? d : 0
            case .text(let s): object[name] = s
            case .color(let c): object[name] = ["__vec3": [finite(c.x), finite(c.y), finite(c.z)]]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// 스크립트 하나를 자기 범위에 가둔 등록문.
    ///
    /// `typeof init`은 선언이 없어도 참조 오류를 내지 않는다. 그래서 스크립트가
    /// 내보내지 않은 콜백은 자연히 undefined가 된다.
    static func unitSource(layerID: Int, script: LayerScript, modules: [String: String]) -> String {
        var properties: [String: Any] = [:]
        for (key, value) in script.scriptProperties { properties[key] = value.jsValue }
        let propertiesJSON = String(
            decoding: (try? JSONSerialization.data(withJSONObject: properties)) ?? Data("{}".utf8),
            as: UTF8.self)
        let bindings = ScriptEngine.moduleBindings(for: script.source, modules: modules)
            .joined(separator: "\n")
        let body = ScriptEngine.stripModuleSyntax(script.source)
        let callbacks = [
            "init", "update", "applyUserProperties", "resizeScreen",
            "mediaPlaybackChanged", "mediaThumbnailChanged", "mediaPropertiesChanged",
            "mediaTimelineChanged", "cursorMove", "cursorClick", "cursorEnter", "cursorLeave",
            "destroy",
        ]
        let exports = callbacks
            .map { "\($0): (typeof \($0) === 'function') ? \($0) : undefined" }
            .joined(separator: ", ")
        return """
        __wfRegister(\(layerID), \(jsString(script.property)), (function (thisLayer, thisObject, __wallflowLayerProperties) {
        \(Self.scriptPropertiesBuilder)
        \(bindings)
        \(body)
        return { \(exports) };
        })(__wf.layers[\(layerID)], __wf.layers[\(layerID)], \(propertiesJSON)));
        """
    }

    /// 재질 상수 스크립트의 등록문. `thisObject`가 재질 상수 묶음이고 `thisLayer`는
    /// 그 재질을 쓰는 레이어다.
    static func materialUnitSource(layerID: Int, script: MaterialScript,
                                   modules: [String: String]) -> String {
        let initial: String
        switch script.value {
        case .scalar(let d)?: initial = "\(finite(d))"
        case .vector(let v)?:
            let c = v.map { finite($0) }
            initial = c.count >= 3 ? "new Vec3(\(c[0]), \(c[1]), \(c[2]))"
                : c.count == 2 ? "new Vec2(\(c[0]), \(c[1]))" : "\(c.first ?? 0)"
        case nil: initial = "undefined"
        }
        let bindings = ScriptEngine.moduleBindings(for: script.source, modules: modules)
            .joined(separator: "\n")
        let body = ScriptEngine.stripModuleSyntax(script.source)
        let exports = ["init", "update", "applyUserProperties", "resizeScreen"]
            .map { "\($0): (typeof \($0) === 'function') ? \($0) : undefined" }
            .joined(separator: ", ")
        return """
        __wfRegisterMaterial(\(layerID), \(jsString(script.key)), \(initial), (function (thisLayer, thisObject, __wallflowLayerProperties) {
        \(Self.scriptPropertiesBuilder)
        \(bindings)
        \(body)
        return { \(exports) };
        })(__wf.layers[\(layerID)], __wfMaterial(\(layerID)), {}));
        """
    }

    /// `createScriptProperties()` 흉내. `ScriptEngine`의 것과 같은 규칙이되 스크립트
    /// 범위 안에 정의한다 — 컨텍스트가 하나라 전역으로 두면 레이어끼리 값이 섞인다.
    static let scriptPropertiesBuilder = """
    function createScriptProperties() {
        var layer = __wallflowLayerProperties || {};
        var builder = {};
        var handler = function (spec) {
            if (spec && spec.name !== undefined && spec.name !== null) {
                builder[spec.name] = Object.prototype.hasOwnProperty.call(layer, spec.name)
                    ? layer[spec.name] : spec.value;
            }
            return proxy;
        };
        var proxy = new Proxy(builder, {
            get: function (target, name) {
                if (name in target) { return target[name]; }
                if (typeof name === 'string' && name.indexOf('add') === 0) { return handler; }
                return undefined;
            }
        });
        builder.finish = function () { return proxy; };
        return proxy;
    }
    """

    /// 씬 전역들. 레퍼런스의 IScene·ILayer·IEngine·IInput을 따른다.
    static let prelude = """
    var __wf = { layers: {}, order: [], units: [], failures: [], camera: null,
                 cameraDirty: false, spawnCount: 0, nextSpawn: -1, audio: [] };

    // 빌더 없이 `scriptProperties`를 바로 읽는 스크립트를 위한 빈 전역. 빌더를 쓰는
    // 스크립트는 자기 범위에 `let scriptProperties`를 두므로 이것을 가린다.
    var scriptProperties = {};
    var MediaPlaybackEvent = { PLAYBACK_PLAYING: 0, PLAYBACK_PAUSED: 1, PLAYBACK_STOPPED: 2 };
    var MediaThumbnailEvent = {};
    // 실물 미디어 위젯이 재생 상태를 저장한다. 세션 안에서만 남는 메모리 저장소다.
    var __wfStorage = {};
    var localStorage = {
        getItem: function (k) { return Object.prototype.hasOwnProperty.call(__wfStorage, k) ? __wfStorage[k] : null; },
        setItem: function (k, v) { if (Object.keys(__wfStorage).length < 256 || k in __wfStorage) { __wfStorage[k] = String(v).slice(0, 4096); } },
        removeItem: function (k) { delete __wfStorage[k]; },
        clear: function () { __wfStorage = {}; }
    };
    // WE의 localStorage는 웹과 달리 get/set이다(실물 미디어 버튼이 `localStorage.get`을 쓴다).
    localStorage.get = localStorage.getItem;
    localStorage.set = localStorage.setItem;
    localStorage.remove = localStorage.removeItem;
    var sessionStorage = localStorage;

    function __wfAnimationStub() {
        return { play: function () {}, pause: function () {}, stop: function () {},
                 setFrame: function () {}, frame: 0, isPlaying: function () { return false; },
                 duration: 0, rate: 1 };
    }

    function __wfArr3(a, d) {
        return (a && a.length >= 3) ? new Vec3(a[0], a[1], a[2]) : new Vec3(d[0], d[1], d[2]);
    }

    function __wfMakeLayer(seed) {
        var L = {
            id: seed.id,
            name: seed.name || '',
            origin: __wfArr3(seed.o, [0, 0, 0]),
            angles: __wfArr3(seed.a, [0, 0, 0]),
            scale: __wfArr3(seed.s, [1, 1, 1]),
            alpha: (typeof seed.al === 'number') ? seed.al : 1,
            visible: seed.v !== false,
            color: __wfArr3(seed.c, [1, 1, 1]),
            size: (seed.sz && seed.sz.length >= 2) ? new Vec2(seed.sz[0], seed.sz[1]) : new Vec2(0, 0),
            text: (typeof seed.t === 'string') ? seed.t : undefined,
            parallaxDepth: new Vec2(0, 0),
            isUserHidden: false,
            pointsize: (typeof seed.pt === 'number') ? seed.pt : undefined,
            instance: {},
            __playing: (typeof seed.p === 'boolean') ? seed.p : undefined,
            volume: (typeof seed.vol === 'number') ? seed.vol : undefined,
            __asset: seed.asset,
            __parent: (typeof seed.parent === 'number') ? seed.parent : null,
            getChildren: function () {
                var me = this.id, out = [];
                for (var i = 0; i < __wf.order.length; i++) {
                    var c = __wf.layers[__wf.order[i]];
                    if (c && c.__parent === me) { out.push(c); }
                }
                return out;
            },
            getParent: function () { return this.__parent === null ? null : (__wf.layers[this.__parent] || null); },
            play: function () { this.__playing = true; },
            stop: function () { this.__playing = false; },
            pause: function () { this.__playing = false; },
            isPlaying: function () { return this.__playing === true; },
            getAnimation: __wfAnimationStub,
            getTextureAnimation: __wfAnimationStub,
            getWidth: function () { return this.size.x; },
            getHeight: function () { return this.size.y; }
        };
        return L;
    }

    function __wfAddLayer(seed) {
        var L = __wfMakeLayer(seed);
        __wf.layers[L.id] = L;
        __wf.order.push(L.id);
        return L;
    }

    function __wfSetCamera(c) {
        if (!c) { __wf.camera = null; return; }
        __wf.camera = { eye: __wfArr3(c.eye, [0, 0, 100]), center: __wfArr3(c.center, [0, 0, 0]),
                        up: __wfArr3(c.up, [0, 1, 0]), fov: c.fov, zoom: 1 };
    }

    function __wfRegister(id, property, exports) {
        var L = __wf.layers[id];
        if (!L || !exports) { return; }
        __wf.units.push({ layer: L, property: property, exports: exports, failures: 0 });
    }

    // 레이어의 재질 상수 묶음. 재질 스크립트의 thisObject다.
    function __wfMaterial(id) {
        var L = __wf.layers[id];
        if (!L) { return {}; }
        if (!L.__material) { L.__material = {}; }
        return L.__material;
    }

    function __wfRegisterMaterial(id, key, initial, exports) {
        var L = __wf.layers[id];
        if (!L || !exports) { return; }
        var m = __wfMaterial(id);
        if (initial !== undefined && m[key] === undefined) { m[key] = initial; }
        __wf.units.push({ layer: L, property: key, material: m, exports: exports, failures: 0 });
    }

    var thisScene = {
        getLayer: function (key) {
            if (typeof key === 'number') { return __wf.layers[key] || null; }
            for (var i = 0; i < __wf.order.length; i++) {
                var L = __wf.layers[__wf.order[i]];
                if (L && L.name === key) { return L; }
            }
            return null;
        },
        getLayerAtIndex: function (i) { return __wf.layers[__wf.order[i]] || null; },
        enumerateLayers: function () {
            return __wf.order.map(function (id) { return __wf.layers[id]; });
        },
        createLayer: function (asset) {
            var path = (typeof asset === 'string') ? asset
                : (asset && typeof asset.__wfAsset === 'string') ? asset.__wfAsset : null;
            var L = __wfMakeLayer({ id: __wf.nextSpawn, name: path || '', asset: path || undefined });
            if (!path || __wf.spawnCount >= \(maxSpawnedLayers)) {
                // 화면에 붙지 않는 빈 레이어. 스크립트는 오류 없이 계속 돈다.
                return L;
            }
            __wf.nextSpawn -= 1;
            __wf.spawnCount += 1;
            __wf.layers[L.id] = L;
            __wf.order.push(L.id);
            return L;
        },
        destroyLayer: function (L) { if (L) { L.visible = false; L.alpha = 0; } },
        sortLayer: function () {},
        getCameraTransforms: function () {
            var c = __wf.camera || { eye: new Vec3(0, 0, 100), center: new Vec3(0, 0, 0),
                                     up: new Vec3(0, 1, 0), zoom: 1 };
            return { eye: c.eye.copy(), center: c.center.copy(), up: c.up.copy(), zoom: c.zoom };
        },
        setCameraTransforms: function (t) {
            if (!t || !__wf.camera) { return; }
            if (t.eye) { __wf.camera.eye = new Vec3(t.eye); }
            if (t.center) { __wf.camera.center = new Vec3(t.center); }
            if (t.up) { __wf.camera.up = new Vec3(t.up); }
            __wf.cameraDirty = true;
        },
        getGlobalAudioMode: function () { return 0; },
        getSetting: function () { return undefined; }
    };

    var input = {
        cursorWorldPosition: new Vec3(0, 0, 0),
        cursorScreenPosition: new Vec2(0, 0),
        cursorDelta: new Vec2(0, 0),
        isCursorVisible: true,
        isCursorInsideScreen: true,
        cursorVisibility: 1
    };

    engine.registerAsset = function (path) { return { __wfAsset: String(path) }; };
    engine.userProperties = {};
    // IAudioBuffers: {resolution, average, left[], right[]}. 값은 틱마다 호스트가 채운다.
    // 레퍼런스의 해상도는 16·32·64다. 다른 값은 가장 가까운 것으로 맞춘다.
    engine.registerAudioBuffers = function (resolution) {
        var r = (resolution === 16 || resolution === 32 || resolution === 64) ? resolution
            : (resolution < 24 ? 16 : (resolution < 48 ? 32 : 64));
        var zeros = function () { var a = []; for (var i = 0; i < r; i++) { a.push(0); } return a; };
        var b = { resolution: r, average: 0, left: zeros(), right: zeros() };
        if (__wf.audio.length < 64) { __wf.audio.push(b); }
        return b;
    };

    function __wfFeedAudio(bands) {
        for (var i = 0; i < __wf.audio.length; i++) {
            var b = __wf.audio[i];
            var src = bands ? bands[String(b.resolution)] : null;
            var sum = 0;
            for (var k = 0; k < b.resolution; k++) {
                var l = src && src.l && typeof src.l[k] === 'number' ? src.l[k] : 0;
                var rr = src && src.r && typeof src.r[k] === 'number' ? src.r[k] : 0;
                b.left[k] = l; b.right[k] = rr; sum += l + rr;
            }
            b.average = b.resolution > 0 ? sum / (2 * b.resolution) : 0;
        }
    }

    function __wfUserProps(raw) {
        var out = {};
        for (var k in raw) {
            var v = raw[k];
            if (v && typeof v === 'object' && v.__vec3) { out[k] = new Vec3(v.__vec3[0], v.__vec3[1], v.__vec3[2]); }
            else { out[k] = v; }
        }
        return out;
    }

    function __wfValue(L, p, u) {
        if (u && u.material) { return u.material[p]; }
        switch (p) {
            case 'visible': return L.visible;
            case 'alpha': return L.alpha;
            case 'text': return L.text;
            case 'size': return L.size;
            default: return L[p];
        }
    }

    function __wfAssign(L, p, r, u) {
        if (r === undefined || r === null) { return; }
        if (u && u.material) {
            if (typeof r === 'number') { if (isFinite(r)) { u.material[p] = r; } }
            else if (typeof r === 'object') { u.material[p] = new Vec3(r); }
            return;
        }
        switch (p) {
            case 'visible': L.visible = !!r; break;
            case 'alpha': if (typeof r === 'number' && isFinite(r)) { L.alpha = r; } break;
            case 'text': L.text = String(r); break;
            case 'size': if (typeof r === 'object') { L.size = new Vec2(r); } break;
            case 'origin': case 'angles': case 'scale': case 'color':
                if (typeof r === 'object') { L[p] = new Vec3(r); } break;
        }
    }

    function __wfCall(u, name, args) {
        var fn = u.exports[name];
        if (typeof fn !== 'function') { return undefined; }
        try {
            var r = fn.apply(undefined, args);
            u.failures = 0;
            return r;
        } catch (e) {
            u.failures += 1;
            __wf.failures.push(u.layer.name + '.' + u.property + ': ' + name + ': ' + e);
            return undefined;
        }
    }

    // from번째부터의 스크립트에 시작 콜백을 돌린다. 뒤늦게 붙은 것만 돌릴 때 from을 준다.
    function __wfRunInit(rawProps, from) {
        var props = __wfUserProps(rawProps);
        engine.userProperties = props;
        var i, u;
        for (i = from; i < __wf.units.length; i++) {
            u = __wf.units[i];
            __wfAssign(u.layer, u.property, __wfCall(u, 'init', [__wfValue(u.layer, u.property, u)]), u);
        }
        for (i = from; i < __wf.units.length; i++) { __wfCall(__wf.units[i], 'applyUserProperties', [props]); }
        for (i = from; i < __wf.units.length; i++) { __wfCall(__wf.units[i], 'resizeScreen', [engine.screenResolution]); }
        // 지금 아무것도 재생 중이 아니다. 미디어 위젯이 이걸로 스스로 숨는다.
        for (i = from; i < __wf.units.length; i++) {
            __wfCall(__wf.units[i], 'mediaPlaybackChanged', [{ state: MediaPlaybackEvent.PLAYBACK_STOPPED }]);
            // 레퍼런스의 IMediaThumbnailEvent: 썸네일이 없어도 색 필드는 Vec3다.
            __wfCall(__wf.units[i], 'mediaThumbnailChanged', [{
                hasThumbnail: false, primaryColor: new Vec3(0, 0, 0), secondaryColor: new Vec3(0, 0, 0),
                tertiaryColor: new Vec3(0, 0, 0), textColor: new Vec3(1, 1, 1), highContrastColor: new Vec3(1, 1, 1)
            }]);
        }
    }

    function __wfSnapshot() {
        var layers = [];
        for (var i = 0; i < __wf.order.length; i++) {
            var L = __wf.layers[__wf.order[i]];
            if (!L) { continue; }
            var o = L.origin || {}, a = L.angles || {}, s = L.scale || {}, c = L.color || {}, sz = L.size || {};
            var entry = { id: L.id, name: String(L.name),
                          o: [+o.x, +o.y, +o.z], a: [+a.x, +a.y, +a.z], s: [+s.x, +s.y, +s.z],
                          al: +L.alpha, v: !!L.visible && !L.isUserHidden,
                          c: [+c.x, +c.y, +c.z], sz: [+sz.x, +sz.y] };
            if (typeof L.text === 'string') { entry.t = L.text; }
            if (typeof L.__playing === 'boolean') { entry.p = L.__playing; }
            if (typeof L.volume === 'number') { entry.vol = L.volume; }
            if (typeof L.pointsize === 'number') { entry.pt = L.pointsize; }
            if (typeof L.__asset === 'string') { entry.asset = L.__asset; }
            if (L.__material) {
                var m = {};
                for (var k in L.__material) {
                    var mv = L.__material[k];
                    if (typeof mv === 'number') { m[k] = mv; }
                    else if (mv && typeof mv === 'object' && typeof mv.x === 'number') {
                        m[k] = (typeof mv.z === 'number') ? [+mv.x, +mv.y, +mv.z] : [+mv.x, +mv.y, 0];
                    }
                }
                entry.m = m;
            }
            layers.push(entry);
        }
        var camera = null;
        if (__wf.cameraDirty && __wf.camera) {
            var cm = __wf.camera;
            camera = { eye: [+cm.eye.x, +cm.eye.y, +cm.eye.z],
                       center: [+cm.center.x, +cm.center.y, +cm.center.z],
                       up: [+cm.up.x, +cm.up.y, +cm.up.z] };
            __wf.cameraDirty = false;
        }
        var failures = __wf.failures;
        __wf.failures = [];
        // NaN·Infinity는 JSON에서 null이 된다. Swift 쪽이 그 자리를 버린다.
        return JSON.stringify({ layers: layers, camera: camera, failures: failures,
                                audio: __wf.audio.length });
    }

    // 커서가 움직였으면 모든 스크립트에 cursorMove를 보낸다. 레퍼런스의 CursorEvent는
    // worldPosition·localPosition·hitBox다. 실물 "졸음" 씬이 이 이벤트로 zzz를 끄고
    // 타이머를 되감는다. 실물 WE는 Solid 표시된 레이어에만 보내지만, 어느 레이어가
    // Solid인지는 씬 파일에 없어서 전부에 보낸다 — 이벤트를 아예 안 보내면 그 타이머가
    // 영영 안 시작된다.
    var __wfLastCursor = null;
    function __wfDispatchCursor(cx, cy, cz) {
        var moved = __wfLastCursor === null
            || Math.abs(__wfLastCursor.x - cx) > 0.01 || Math.abs(__wfLastCursor.y - cy) > 0.01;
        __wfLastCursor = new Vec3(cx, cy, cz);
        if (!moved) { return; }
        input.cursorDelta = new Vec2(0, 0);
        for (var i = 0; i < __wf.units.length; i++) {
            var u = __wf.units[i];
            if (u.failures >= \(maxConsecutiveFailures) || typeof u.exports.cursorMove !== 'function') { continue; }
            var o = u.layer.origin || new Vec3(0, 0, 0);
            __wfCall(u, 'cursorMove', [{
                worldPosition: new Vec3(cx, cy, cz),
                localPosition: new Vec3(cx - o.x, cy - o.y, 0),
                hitBox: null
            }]);
        }
    }

    function __wfTick(frametime, runtime, cx, cy, cz, sx, sy, audio) {
        engine.frametime = frametime;
        engine.runtime = runtime;
        input.cursorWorldPosition = new Vec3(cx, cy, cz);
        input.cursorScreenPosition = new Vec2(sx, sy);
        __wfFeedAudio(audio);
        __wfDispatchCursor(cx, cy, cz);
        for (var i = 0; i < __wf.units.length; i++) {
            var u = __wf.units[i];
            if (u.failures >= \(maxConsecutiveFailures)) { continue; }
            __wfAssign(u.layer, u.property, __wfCall(u, 'update', [__wfValue(u.layer, u.property, u)]), u);
        }
        return __wfSnapshot();
    }
    """
}
