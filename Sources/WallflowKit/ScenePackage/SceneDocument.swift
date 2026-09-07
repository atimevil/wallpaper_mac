import Foundation

public enum SceneError: Error, Equatable {
    case malformedSceneJSON
    case missingField(String)
    /// 원근 투영 씬. `orthogonalprojection`이 JSON `null`로 들어온다.
    ///
    /// 실물 창작마당 씬 하나("Ocarina of Time")가 이 경우다. 3D 카메라가 필요해서
    /// 직교 투영 파이프라인으로는 그릴 수 없다. `missingField`로 뭉개면 파일이
    /// 깨진 것처럼 보여서 원인을 찾는 데 오래 걸린다.
    case perspectiveProjectionUnsupported
}

/// scene.json과 그것이 참조하는 models/·materials/를 따라가
/// "무엇을 어디에 그릴지"의 목록으로 바꾼다.
///
/// 참조 사슬 (실물에서 확인):
///   object.image → models/X.json의 "material"
///                → materials/Y.json의 passes[0].textures[0]
///                → materials/<그 이름>.tex
public struct SceneDocument: Sendable {
    public let orthoWidth: Int
    public let orthoHeight: Int
    public let clearColor: Vec3
    /// 원근 씬의 카메라. 직교 씬이면 nil이다.
    public let camera: SceneCamera?
    public var isPerspective: Bool { camera != nil }
    public let clearEnabled: Bool
    public let layers: [SceneLayer]
    /// 마우스를 따라 레이어를 조금씩 미는 정도. 0이면 끈 것이다.
    ///
    /// WE의 특징적인 움직임이라 없으면 씬이 납작해 보인다. 레이어마다
    /// `parallaxDepth`가 있고 화면 중심에서 마우스가 떨어진 만큼 곱해 민다.
    /// 스크립트가 `import * as X from 'Y'`로 불러오는 모듈들(이름 → 본문).
    ///
    /// JavaScriptCore는 ES 모듈을 모르므로 스크립트를 돌릴 때 미리 심어 줘야 한다.
    /// 씬마다 같은 모듈을 여러 스크립트가 쓰므로 문서에서 한 번만 읽는다.
    public let scriptModules: [String: String]
    public let parallaxAmount: Double

    /// 도형(`shape: quad`) 레이어의 기준 한 변. 파일에는 크기가 없다.
    /// 근거는 `presets/lightshafts/`의 미리보기 씬(256x256 캔버스)과
    /// 같은 이펙트의 미리보기가 쓰는 256x256 이미지 레이어다.
    static let shapeQuadBaseSize = 256.0

    public static func load(from reader: PkgReader) throws -> SceneDocument {
        try load(from: reader, assets: nil)
    }

    /// 사용자가 바꾼 속성값을 씬 JSON에 얹는다.
    ///
    /// 씬은 속성을 `{"user": "이름", "value": …}`로 가리키고, 파서들은 그 `value`를
    /// 읽는다(색·알파·보임·이펙트 상수 전부). 그래서 **트리를 한 번 훑어 `value`만
    /// 바꿔치기**하면 파서를 하나도 안 건드리고 전부에 먹는다. 레이어든 이펙트
    /// 패스든 자리를 가리지 않는다.
    static func applyingUserOverrides(
        _ node: Any, overrides: [String: UserPropertyValue]
    ) -> Any {
        guard !overrides.isEmpty else { return node }
        if var dict = node as? [String: Any] {
            if let name = dict["user"] as? String, let value = overrides[name],
               dict["value"] != nil {
                dict["value"] = value.sceneJSONValue
                return dict
            }
            for (key, child) in dict {
                dict[key] = applyingUserOverrides(child, overrides: overrides)
            }
            return dict
        }
        if let array = node as? [Any] {
            return array.map { applyingUserOverrides($0, overrides: overrides) }
        }
        return node
    }

    /// 씬 정의가 든 항목 이름.
    ///
    /// 보통 `scene.json`이지만 늘 그런 것은 아니다. 실물 창작마당 씬에
    /// `gifscene.json`인 것이 있다(패키지 이름도 `gifscene.pkg`다). 하드코딩하면
    /// 그런 씬은 통째로 열리지 않는다. 없으면 최상위의 다른 `.json`을 쓴다 —
    /// 씬 패키지에는 최상위 json이 하나뿐이다.
    static func sceneEntryName(in reader: PkgReader) -> String {
        if reader.contains("scene.json") { return "scene.json" }
        let candidates = reader.names.filter {
            $0.hasSuffix(".json") && !$0.contains("/")
        }.sorted()
        return candidates.first ?? "scene.json"
    }

    public static func load(
        from reader: PkgReader, assets: AssetsStore?,
        userOverrides: [String: UserPropertyValue] = [:]
    ) throws -> SceneDocument {
        let raw = try reader.data(for: Self.sceneEntryName(in: reader))
        guard let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }
        let root = applyingUserOverrides(parsed, overrides: userOverrides) as? [String: Any]
            ?? parsed

        let general = root["general"] as? [String: Any] ?? [:]
        // 키는 있는데 값이 null이면 직교가 아니라 원근 투영 씬이다.
        // 값이 없는 것과 형태가 다른 것을 구분해야 진단이 맞다.
        //
        // **원근 씬은 3D 모델까지 있어야 뜻이 있다.** 실물 원근 씬을 재 보니
        // 레이어 26개 중 우리가 그릴 수 있는 것이 6개뿐이고, 그 씬의 중심인
        // 프리즘 넷이 `.mdl` 3D 메시다. 투영만 넣어 그리면 배경 평면 몇 장만
        // 뜬 깨진 화면이 된다 — 미리보기로 물러나는 편이 낫다.
        // 카메라도 스크립트가 움직인다(`Camera (script)`, `OMGMatrix`).
        // 원근 씬에는 직교 크기가 없다. 좌표가 픽셀이 아니라 세계 단위이고
        // 화면 비율은 그릴 때 정해진다. 글자·파티클처럼 직교 크기를 쓰는
        // 경로를 위해 이름뿐인 1920x1080을 둔다.
        let camera: SceneCamera?
        let width: Int
        let height: Int
        if general.keys.contains("orthogonalprojection"),
           !(general["orthogonalprojection"] is [String: Any]) {
            camera = SceneCamera.parse(general)
            width = 1920
            height = 1080
        } else {
            guard let ortho = general["orthogonalprojection"] as? [String: Any],
                  let w = ortho["width"] as? Int, let h = ortho["height"] as? Int,
                  w > 0, h > 0 else {
                throw SceneError.missingField("orthogonalprojection")
            }
            camera = nil
            width = w
            height = h
        }

        let clearColor = (general["clearcolor"] as? String).flatMap(Vec3.parse)
            ?? Vec3(x: 0, y: 0, z: 0)
        let clearEnabled = general["clearenabled"] as? Bool ?? true

        let resolver = ReferenceResolver(pkg: reader, assets: assets)

        // 배열 조건부 캐스트는 전부-아니면-전무다. 원소 하나가 딕셔너리가 아니면
        // 통째로 실패해 정상 레이어까지 사라진다. 원소별로 걸러 그것을 막는다.
        let rawObjects = root["objects"] as? [Any] ?? []
        let objects = rawObjects.compactMap { $0 as? [String: Any] }
        // 부모-자식 변환을 먼저 푼다. 자식의 origin과 scale은 부모 기준 상대값이라,
        // 무시하면 시계가 화면 밖에 그려지고 글자 크기가 어긋난다(실물에서 확인).
        let transforms = resolveTransforms(objects)
        let rawLayers = objects.enumerated().map { index, object -> SceneLayer in
            let id = object["id"] as? Int ?? index
            let layer = makeLayer(isPerspective: camera != nil, object, fallbackID: index, resolver: resolver,
                                  transform: transforms[id] ?? .identity,
                                  canvas: Vec2(x: Double(width), y: Double(height)))
            // 스크립트는 레이어가 숨어 있어도 붙인다. 실물 원근 씬의 카메라·프리즘
            // 로직이 보이지 않는 레이어의 `visible` 스크립트에 산다.
            return layer.attachingScripts(
                layerScripts(of: object), angles: ownAngles(of: object),
                localOrigin: scalarOrScripted(object["origin"]).flatMap(Vec3.parse)
                    ?? Vec3(x: 0, y: 0, z: 0),
                localScale: scalarOrScripted(object["scale"]).flatMap(Vec3.parse)
                    ?? Vec3(x: 1, y: 1, z: 1))
        }
        let layers = applyingParticleBudget(rawLayers)
        let scriptModules = loadScriptModules(objects: objects, resolver: resolver)

        // cameraparallax가 꺼져 있으면 강도를 0으로 본다.
        let parallaxOn = boolValue(general["cameraparallax"]) ?? false
        let amount = doubleValue(general["cameraparallaxamount"]) ?? 0
        return SceneDocument(
            orthoWidth: width, orthoHeight: height,
            clearColor: clearColor, camera: camera, clearEnabled: clearEnabled,
            layers: layers,
            scriptModules: scriptModules,
            parallaxAmount: parallaxOn && amount.isFinite ? Swift.min(Swift.max(amount, 0), 2) : 0
        )
    }

    /// 스크립트가 붙을 수 있는 속성 키. 이 순서로 돈다.
    public static let scriptableProperties = [
        "visible", "origin", "angles", "scale", "size", "alpha", "color", "text",
    ]

    /// 오브젝트의 속성 스크립트 전부. `text`는 `text` 객체 안에 있다.
    static func layerScripts(of object: [String: Any]) -> [LayerScript] {
        var scripts: [LayerScript] = []
        for key in scriptableProperties {
            guard let holder = object[key] as? [String: Any],
                  let source = holder["script"] as? String else { continue }
            var properties: [String: ScriptPropertyValue] = [:]
            for (name, raw) in (holder["scriptproperties"] as? [String: Any] ?? [:]) {
                if let n = raw as? NSNumber, !(raw is String) {
                    properties[name] = .number(n.doubleValue)
                } else if let t = raw as? String {
                    properties[name] = .text(t)
                }
            }
            scripts.append(LayerScript(property: key, source: source, scriptProperties: properties))
        }
        return scripts
    }

    /// 오브젝트 자체의 회전(도). 부모를 합치지 않는다.
    static func ownAngles(of object: [String: Any]) -> Vec3 {
        scalarOrScripted(object["angles"]).flatMap(Vec3.parse) ?? Vec3(x: 0, y: 0, z: 0)
    }

    /// 스크립트가 `thisScene.createLayer(asset)`으로 만든 레이어.
    ///
    /// 자산 경로만으로 레이어를 만든다 — `.mdl`이면 3D 메시, 파티클 프리셋이면
    /// 파티클, 소리 파일이면 소리다. 배치는 원점·배율 1이고 스크립트가 곧 옮긴다.
    /// 만들 수 없는 자산은 nil — 스크립트 쪽에는 빈 레이어 객체가 남아 오류 없이 돈다.
    public static func layer(
        fromAsset path: String, id: Int, resolver: ReferenceResolver,
        isPerspective: Bool, canvas: Vec2
    ) -> SceneLayer? {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        var object: [String: Any] = ["id": id, "name": name, "origin": "0 0 0", "visible": true]
        switch ext {
        case "mdl":
            object["model"] = path
        case "json":
            // 파티클 프리셋은 `emitter`가 있다. 재질(`passes`)은 레이어가 못 된다.
            guard let json = resolver.json(for: path), json["emitter"] != nil else { return nil }
            object["particle"] = path
        case "ogg", "mp3", "wav", "flac":
            object["sound"] = [path]
            object["startsilent"] = true
            object["playbackmode"] = "loop"
            object["volume"] = 1.0
        default:
            return nil
        }
        let layer = makeLayer(isPerspective: isPerspective, object, fallbackID: id,
                              resolver: resolver, transform: .identity, canvas: canvas)
        if case .unsupported = layer.content { return nil }
        return layer
    }

    /// 스크립트들이 import하는 모듈을 assets에서 읽어 온다.
    ///
    /// 실물에 `WEMath`·`WEColor`·`WEVector` 셋이 있고 전부
    /// `scripts/jsmodules/<소문자 이름>.js`에 들어 있다. 파일 이름은 소문자인데
    /// import 이름은 대문자라 그대로 찾으면 못 찾는다.
    static func loadScriptModules(
        objects: [[String: Any]], resolver: ReferenceResolver
    ) -> [String: String] {
        var wanted: Set<String> = []
        for object in objects {
            for key in scriptableProperties {
                guard let script = (object[key] as? [String: Any])?["script"] as? String
                else { continue }
                for line in script.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("import ") else { continue }
                    let quoted = trimmed.split(separator: "'").dropFirst().first
                        ?? trimmed.split(separator: "\"").dropFirst().first
                    if let quoted { wanted.insert(String(quoted)) }
                }
            }
        }
        var modules: [String: String] = [:]
        for name in wanted {
            let path = "scripts/jsmodules/\(name.lowercased()).js"
            guard let data = resolver.data(for: path),
                  let body = String(data: data, encoding: .utf8) else { continue }
            modules[name] = body
        }
        return modules
    }

    /// 씬 전체의 파티클 총량을 예산 안으로 죈다.
    ///
    /// 프리셋 하나의 상한만으로는 부족하다 — 파티클 레이어가 여섯인 씬이 있고,
    /// `instanceoverride`가 개수를 올리기도 한다(실물에서 2,000 → 8,000).
    /// 넘치면 **모든 파티클 레이어를 같은 배율로** 줄인다. 큰 것만 자르면
    /// 레이어 사이의 밀도 관계가 깨져 씬이 다른 그림이 된다.
    static func applyingParticleBudget(_ layers: [SceneLayer]) -> [SceneLayer] {
        var total = 0
        for layer in layers {
            if case .particle(let preset, _, _, _, _) = layer.content { total += preset.maxCount }
        }
        let factor = ParticlePreset.budgetScale(forTotalCount: total)
        guard factor < 1 else { return layers }
        return layers.map { layer in
            guard case .particle(let preset, let texturePath, let blend, let normalPath,
                                 let refractAmount) = layer.content else {
                return layer
            }
            return layer.replacingContent(
                .particle(preset: preset.scaledToBudget(factor),
                          texturePath: texturePath, blend: blend, normalPath: normalPath,
                          refractAmount: refractAmount))
        }
    }

    /// 레이어 하나의 최종 배치. 부모 사슬을 이미 합쳐 놓은 값이다.
    struct LayerTransform {
        var origin: Vec3
        var scale: Vec3
        /// 화면 평면 회전(라디안). 실물에서 z 말고는 쓰이지 않는다.
        var rotation: Double
        /// 부모의 투명도가 곱해진 값.
        var alpha: Double
        /// 부모가 하나라도 숨겨져 있으면 false.
        var visible: Bool

        static let identity = LayerTransform(
            origin: Vec3(x: 0, y: 0, z: 0),
            scale: Vec3(x: 1, y: 1, z: 1),
            rotation: 0, alpha: 1, visible: true)
    }

    /// 오브젝트마다 부모 사슬을 따라 올라가며 변환을 합친다.
    ///
    /// 자식의 origin은 부모 좌표계 안의 값이다. 부모의 크기 조정과 회전을 거쳐야
    /// 화면 좌표가 된다. 실물 씬에서 시계가 부모 그룹 안에 들어 있고 자체 origin이
    /// `(0, -121)`인데, 부모를 무시하면 화면 왼쪽 위 밖에 그려진다.
    ///
    /// 부모 사슬은 파일에서 온 값이라 고리가 있을 수 있다. 깊이를 죄어 멈춘다.
    private static func resolveTransforms(
        _ objects: [[String: Any]]
    ) -> [Int: LayerTransform] {
        var byID: [Int: [String: Any]] = [:]
        for (index, object) in objects.enumerated() {
            byID[object["id"] as? Int ?? index] = object
        }

        func local(_ object: [String: Any]) -> LayerTransform {
            LayerTransform(
                origin: scalarOrScripted(object["origin"]).flatMap(Vec3.parse)
                    ?? Vec3(x: 0, y: 0, z: 0),
                scale: scalarOrScripted(object["scale"]).flatMap(Vec3.parse)
                    ?? Vec3(x: 1, y: 1, z: 1),
                rotation: scalarOrScripted(object["angles"]).flatMap(Vec3.parse)?.z ?? 0,
                alpha: doubleValue(object["alpha"]).map { Swift.min(Swift.max($0, 0), 1) } ?? 1,
                visible: boolValue(object["visible"]) ?? true)
        }

        /// 부모 변환 안에 놓인 자식의 화면 변환.
        func compose(parent: LayerTransform, child: LayerTransform) -> LayerTransform {
            let scaledX = child.origin.x * parent.scale.x
            let scaledY = child.origin.y * parent.scale.y
            let cosR = cos(parent.rotation), sinR = sin(parent.rotation)
            return LayerTransform(
                origin: Vec3(
                    x: parent.origin.x + scaledX * cosR - scaledY * sinR,
                    y: parent.origin.y + scaledX * sinR + scaledY * cosR,
                    z: parent.origin.z + child.origin.z * parent.scale.z),
                scale: Vec3(
                    x: parent.scale.x * child.scale.x,
                    y: parent.scale.y * child.scale.y,
                    z: parent.scale.z * child.scale.z),
                rotation: parent.rotation + child.rotation,
                // 그룹의 투명도는 자식에게 곱해진다. 전파하지 않으면 숨겨진 음악
                // 재생기 UI가 흰 막대로 화면에 남는다(실물에서 확인).
                alpha: parent.alpha * child.alpha,
                visible: parent.visible && child.visible)
        }

        var resolved: [Int: LayerTransform] = [:]
        for (id, object) in byID {
            // 사슬을 위로 모은 뒤 부모부터 차례로 합친다.
            var chain: [[String: Any]] = [object]
            var seen: Set<Int> = [id]
            var current = object
            // disablepropagation이 켜져 있으면 부모 변환을 물려받지 않는다.
            // 보유한 씬에서는 전부 0이라 지금은 무해하지만, 1인 씬을 만나면
            // 그 레이어가 부모를 따라 엉뚱한 자리로 끌려간다.
            let inherits = !(boolValue(object["disablepropagation"]) ?? false)
            // 실물의 가장 깊은 사슬이 3단이다. 32면 충분히 관대하면서도 고리를 끊는다.
            for _ in 0..<32 where inherits {
                guard let parentID = current["parent"] as? Int,
                      !seen.contains(parentID),
                      let parent = byID[parentID] else { break }
                seen.insert(parentID)
                chain.append(parent)
                current = parent
            }
            var transform = LayerTransform.identity
            for object in chain.reversed() {
                transform = compose(parent: transform, child: local(object))
            }
            resolved[id] = transform
        }
        return resolved
    }

    /// 레이어 하나가 해석되지 않아도 씬 전체를 버리지 않는다.
    /// 그릴 수 없는 것은 이유를 달아 unsupported로 남긴다.
    private static func makeLayer(
        isPerspective: Bool = false,
        _ object: [String: Any], fallbackID: Int, resolver: ReferenceResolver,
        transform: LayerTransform, canvas: Vec2
    ) -> SceneLayer {
        let id = object["id"] as? Int ?? fallbackID
        let name = object["name"] as? String ?? "object\(fallbackID)"
        // visible이 {"script": ..., "value": 0} 객체인 레이어가 많다. Bool 캐스트만
        // 시도하면 실패해 기본값 true가 되고, 숨겨야 할 레이어가 화면에 남는다.
        // 실물 "flowery"가 value 0인데 그려지고 있었다.
        // 부모 사슬의 표시 상태가 이미 합쳐져 있다. 그룹이 숨으면 자식도 숨는다.
        let visible = transform.visible
        // alpha와 color를 무시하면 반투명하게 설계된 UI가 불투명한 검은 상자가 된다.
        let alpha = transform.alpha
        let tint = Self.scalarOrScripted(object["color"]).flatMap(Vec3.parse)
            ?? Vec3(x: 1, y: 1, z: 1)
        let rotation = transform.rotation.isFinite ? transform.rotation : 0
        // 실물은 문자열("0.2 0.2")이거나 수다. 앞 성분만 쓴다 — 축별로 다른 씬을 못 봤다.
        let depth: Double = {
            if let n = doubleValue(object["parallaxDepth"]) { return n }
            if let s = object["parallaxDepth"] as? String, let v = Vec2.parse(s) { return v.x }
            return 0
        }()

        // 섞는 방식과 밝기는 짝이다. 밝기 5.56짜리 시계는 오버레이로 섞이는 것을
        // 전제로 그 값이라, 하나만 읽으면 글자가 하얗게 타 버린다.
        // 값은 그대로 두고 판정하지 않는다 — 모르는 번호는 셰이더가 보통으로 그린다.
        let blendMode = (object["colorBlendMode"] as? NSNumber)?.intValue ?? 0
        // 밝기는 음수일 이유가 없고, 실물 최대가 6.24다. 상한을 크게 잡아 둔다 —
        // 큰 값이 셰이더로 흘러가면 그 레이어가 통째로 하얗게 탄다.
        // 무한대와 NaN은 `doubleValue`가 이미 걸러 nil로 준다.
        let brightness = Swift.min(Swift.max(doubleValue(object["brightness"]) ?? 1, 0), 64)

        // origin/size가 문자열이 아니라 {"script": ..., "value": ...} 객체인 씬이 있다.
        // 그 객체에도 `value`가 있고 그게 편집기에서 마지막으로 정해진 좌표다.
        // 스크립트를 아직 못 돌려도 이 값으로 제자리에 그릴 수 있다 —
        // 실물 씬 하나는 origin 스크립트의 update가 통째로 주석 처리돼 있어
        // `value`가 유일한 좌표다.
        // 부모 사슬을 합친 화면 좌표를 쓴다. 자체 origin은 부모 안의 상대값이다.
        // 자체 좌표가 읽히지 않으면(NaN 포함) 레이어를 버린다 — 합친 값이 0이 되어
        // 화면 한복판에 그려지면 파일이 이상한 것을 정상처럼 보이게 한다.
        // origin이 **없는 것**과 **읽히지 않는 것**은 다르다. 부모가 있는데 origin이
        // 없으면 "부모와 같은 자리"라는 뜻이고, 부모 사슬을 합친 값이 이미 그 좌표다.
        // 둘을 같이 버려서 실물 음악 위젯의 진행 막대가 통째로 사라졌다.
        let originIsRelativeToParent = object["origin"] == nil && object["parent"] != nil
        let ownOriginParsed = originIsRelativeToParent
            || Self.scalarOrScripted(object["origin"]).flatMap(Vec3.parse) != nil
        // 부모가 비유한 scale이나 회전을 갖고 있으면 합친 값도 오염된다.
        let composedIsFinite = transform.origin.x.isFinite && transform.origin.y.isFinite
            && transform.scale.x.isFinite && transform.scale.y.isFinite
        let origin = ownOriginParsed && composedIsFinite ? transform.origin : nil
        // 크기에도 scale이 곱해진다. 무시하면 실물 시계가 67% 크게 나온다.
        let size = Self.scalarOrScripted(object["size"]).flatMap(Vec2.parse).map {
            Vec2(x: $0.x * transform.scale.x, y: $0.y * transform.scale.y)
        }
        // 스크립트가 붙어 있는데 우리가 못 돌리는 경우를 사용자에게 알린다.
        var unrun: [String] = []
        var displayScripts: [DisplayScript] = []
        for key in ["origin", "size", "scale", "alpha", "color", "visible"] {
            guard let script = (object[key] as? [String: Any])?["script"] as? String
            else { continue }
            // 속성 스크립트는 전부 `SceneScriptHost`가 돌린다. 이 목록은
            // 테스트가 보는 것이라 유지한다.
            if let property = DisplayScript.Property(rawValue: key) {
                displayScripts.append(DisplayScript(property: property, source: script))
            }
        }
        // 호스트가 모르는 키만 못 돌린 것으로 남긴다.
        for key in ["pointsize"] where (object[key] as? [String: Any])?["script"] != nil {
            unrun.append(key)
        }

        // 레이어에 걸린 이펙트. 못 읽는 것은 조용히 빠진다 — 이펙트 하나 때문에
        // 레이어를 버리면 그림이 통째로 사라진다.
        var effects: [LayerEffect] = []
        for case let raw as [String: Any] in (object["effects"] as? [Any] ?? []) {
            guard let file = raw["file"] as? String else { continue }
            // `visible: false`인 이펙트는 편집기에서 꺼 둔 것이다.
            if let visible = boolValue(raw["visible"]), !visible { continue }
            let scenePasses = (raw["passes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            guard let definition = EffectDefinition.load(
                path: file, scenePasses: scenePasses, resolver: resolver) else { continue }
            effects.append(LayerEffect(
                definition: definition, base: (file as NSString).deletingLastPathComponent))
        }

        func unsupported(_ reason: String) -> SceneLayer {
            SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .unsupported(reason: reason), unrunScripts: unrun,
                alpha: alpha, tint: tint, rotation: rotation,
                displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                colorBlendMode: blendMode, brightness: brightness
            )
        }

        if let particlePresetPath = object["particle"] as? String {
            guard let origin else {
                return unsupported("파티클 레이어지만 origin이 스크립트다. 스크립팅은 M5에서 지원한다")
            }
            let particleSize = (object["size"] as? String).flatMap(Vec2.parse)
                ?? Vec2(x: 0, y: 0)
            // 씬은 프리셋을 그대로 쓰지 않고 instanceoverride로 개수·속도·크기를
            // 배로 조절한다. 무시하면 의도와 전혀 다른 밀도로 뿌린다.
            let override = (object["instanceoverride"] as? [String: Any])
                .map(ParticleOverride.parse) ?? ParticleOverride()
            let content = resolveParticleContent(
                presetPath: particlePresetPath, resolver: resolver, override: override)
            return SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin, size: particleSize,
                content: content, unrunScripts: unrun, alpha: alpha, tint: tint, rotation: rotation,
                displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                colorBlendMode: blendMode, brightness: brightness
            )
        }

        // 3D 메시. 파일은 그릴 때 읽는다 — 여기서는 경로와 스킨만 잡는다.
        // 실물 `mainPrism`은 origin이 없다(원점). 크기도 없다 — 메시가 정한다.
        if let meshPath = object["model"] as? String, !meshPath.isEmpty {
            let skin = Swift.max(0, (object["skin"] as? NSNumber)?.intValue ?? 0)
            return SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .model(path: meshPath, skin: skin), unrunScripts: unrun,
                alpha: alpha, tint: tint, rotation: rotation,
                displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                colorBlendMode: blendMode, brightness: brightness)
        }
        guard let modelPath = object["image"] as? String else {
            // text가 객체가 아니라 그냥 문자열인 레이어가 있다(실물 "Audio visualizer").
            // 스크립트 없이 고정 글자만 그리는 경우다.
            let textObject: [String: Any]? = (object["text"] as? [String: Any])
                ?? (object["text"] as? String).map { ["value": $0] }
            if let text = textObject {
                guard let origin else {
                    return unsupported("텍스트 레이어의 origin에 좌표가 없다")
                }
                return SceneLayer(
                    id: id, name: name, visible: visible,
                    origin: origin, size: size ?? Vec2(x: 0, y: 0),
                    content: .text(makeTextLayer(text, object: object)),
                    unrunScripts: unrun, alpha: alpha, tint: tint, rotation: rotation,
                    displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                    colorBlendMode: blendMode, brightness: brightness)
            }
            if let sound = makeSoundLayer(object) {
                // 소리는 화면을 차지하지 않는다. origin이 없어도 상관없다.
                return SceneLayer(
                    id: id, name: name, visible: visible,
                    origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                    size: size ?? Vec2(x: 0, y: 0),
                    content: .sound(sound), unrunScripts: unrun,
                    alpha: alpha, tint: tint, rotation: rotation,
                    displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                    colorBlendMode: blendMode, brightness: brightness)
            }
            if object["sound"] != nil { return unsupported("소리 파일 목록을 읽지 못했다") }
            // 도형 레이어. 그림 없는 사각형이고, 거기 붙은 이펙트가 그림을 만든다
            // (실물은 전부 `quad` + `lightshafts`인 빛줄기다).
            //
            // **파일에 크기가 없다.** 근거를 assets에서 찾았다: 편집기가 이 레이어를
            // 만드는 프리셋(`presets/lightshafts/`)의 미리보기 씬이 256x256
            // 캔버스이고 도형이 scale 1.2로 그 안을 채운다. 같은 이펙트의 미리보기가
            // 쓰는 이미지 레이어도 정확히 256x256이다. 그래서 기준 변을 256으로 본다.
            if let shape = object["shape"] as? String {
                guard shape == "quad" else {
                    return unsupported("아직 모르는 도형이다: \(shape)")
                }
                guard let origin else {
                    return unsupported("도형 레이어의 origin을 읽을 수 없다")
                }
                let base = Self.shapeQuadBaseSize
                return SceneLayer(
                    id: id, name: name, visible: visible, origin: origin,
                    size: Vec2(x: base * transform.scale.x, y: base * transform.scale.y),
                    content: .solidColor(Vec3(x: 1, y: 1, z: 1)),
                    unrunScripts: unrun, effects: effects, alpha: alpha, tint: tint,
                    rotation: rotation, displayScripts: displayScripts,
                    scale: transform.scale, parallaxDepth: depth,
                    colorBlendMode: blendMode, brightness: brightness)
            }
            return unsupported("알 수 없는 레이어 종류")
        }
        // 원근 씬의 이미지 레이어는 origin이 없는 것이 보통이다 — 원점에 놓인
        // 세계 단위의 판이다(실물 배경 구름). 직교 씬에서는 원점이 화면 왼쪽
        // 아래 구석이라 그런 파일은 깨진 것으로 보는 편이 맞다.
        let placedOrigin = origin
            ?? (isPerspective && size != nil && object["origin"] == nil ? Vec3(x: 0, y: 0, z: 0) : nil)
        guard let origin = placedOrigin, let size else {
            // origin과 size가 아예 없고 effects만 있으면 후처리 레이어다.
            // 실물 "Couche de post-traitement"가 이 경우인데, 스크립트 탓이라고
            // 말하면 사용자를 엉뚱한 원인으로 보낸다.
            // 화면 전체에 거는 후처리 레이어. `fullscreenlayer` 모델을 쓰고
            // origin도 size도 없다 — 화면이 곧 그 크기다.
            if object["origin"] == nil, object["size"] == nil, object["effects"] != nil {
                guard !effects.isEmpty else {
                    return unsupported("후처리 레이어인데 걸 이펙트가 없다")
                }
                return SceneLayer(
                    id: id, name: name, visible: visible,
                    origin: Vec3(x: 0, y: 0, z: 0),
                    size: canvas,
                    content: .postProcess, unrunScripts: unrun, effects: effects,
                    alpha: alpha, tint: tint, rotation: rotation,
                    displayScripts: displayScripts, scale: transform.scale,
                    parallaxDepth: depth,
                    colorBlendMode: blendMode, brightness: brightness)
            }
            return unsupported("origin이나 size를 읽을 수 없다")
        }

        // 이펙트가 모양을 통째로 만드는 단색 레이어(`util/white` + `gradientopacity`)는
        // 한동안 건너뛰었다. 이펙트를 못 걸던 때는 불투명한 흰 판이 그대로 남았기
        // 때문이다. 이제 이펙트를 걸 수 있으므로 그린다 — 걸지 못하면 렌더러가
        // 그 레이어를 원본으로 되돌린다.

        let content = resolveContent(modelPath: modelPath, object: object, resolver: resolver)
        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: content, unrunScripts: unrun, effects: effects, alpha: alpha, tint: tint,
            rotation: rotation, displayScripts: displayScripts, scale: transform.scale, parallaxDepth: depth,
                colorBlendMode: blendMode, brightness: brightness
        )
    }

    /// Bool이거나 수(0/1)이거나, `{"value": ...}` 객체면 그 값.
    private static func boolValue(_ raw: Any?) -> Bool? {
        let value = (raw as? [String: Any])?["value"] ?? raw
        if let b = value as? Bool { return b }
        if let d = value as? Double { return d != 0 }
        return nil
    }

    /// 수이거나 `{"value": ...}` 객체면 그 값. 비유한값은 없는 것으로 본다 —
    /// NaN 알파가 셰이더까지 흘러가면 레이어가 통째로 사라진다.
    private static func doubleValue(_ raw: Any?) -> Double? {
        let value = (raw as? [String: Any])?["value"] ?? raw
        guard let d = value as? Double, d.isFinite else { return nil }
        return d
    }

    /// 문자열이거나, `{"script": ..., "value": ...}` 객체면 그 `value`.
    private static func scalarOrScripted(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        return (raw as? [String: Any])?["value"] as? String
    }

    /// 소리 레이어를 읽는다. `sound`는 경로 배열이다.
    private static func makeSoundLayer(_ object: [String: Any]) -> SoundLayer? {
        let raw = object["sound"]
        let paths: [String]
        if let list = raw as? [Any] {
            paths = list.compactMap { $0 as? String }
        } else if let single = raw as? String {
            paths = [single]
        } else {
            return nil
        }
        guard !paths.isEmpty else { return nil }
        // volume도 {"script": ..., "value": ...} 객체로 올 수 있다.
        let volume = doubleValue(object["volume"]).map { Swift.min(Swift.max($0, 0), 1) } ?? 1
        return SoundLayer(
            paths: paths,
            volume: volume,
            // 실물에 loop와 single이 있다. 모르는 값은 반복하지 않는 쪽이 안전하다.
            loops: (object["playbackmode"] as? String) == "loop",
            startsSilent: boolValue(object["startsilent"]) ?? false)
    }

    /// 텍스트 레이어를 읽는다.
    ///
    /// 실패시킬 이유가 거의 없다 — 폰트가 없거나 글자가 비어도 나중에 래스터화가
    /// 판단한다. 여기서 unsupported로 떨구면 사용자는 "왜 시계가 없지"만 알 뿐
    /// 무엇이 없는지 모른다.
    private static func makeTextLayer(
        _ text: [String: Any], object: [String: Any]
    ) -> TextLayer {
        // 값이 수만 있는 게 아니다. 실물 시계의 delimiter는 ":"라는 문자열이고,
        // 이걸 버리면 스크립트가 "00" + undefined + "22"를 만든다.
        var properties: [String: ScriptPropertyValue] = [:]
        if let props = text["scriptproperties"] as? [String: Any] {
            for (key, value) in props {
                // 문자열을 먼저 본다. 나머지는 전부 수로 담는다 —
                // JSON의 true/false도 NSNumber라 1/0이 된다(자바스크립트에선 같다).
                if let s = value as? String { properties[key] = .text(s) }
                else if let b = value as? Bool { properties[key] = .number(b ? 1 : 0) }
                else if let d = value as? Double { properties[key] = .number(d) }
            }
        }
        return TextLayer(
            value: text["value"] as? String ?? "",
            fontPath: object["font"] as? String ?? "systemfont",
            // 실물 텍스트의 color는 이미 0~1이다. 파티클(0~255)과 다르니 나누지 마라.
            color: (object["color"] as? String).flatMap(Vec3.parse) ?? Vec3(x: 1, y: 1, z: 1),
            script: text["script"] as? String,
            scriptProperties: properties,
            // 실물에 left·center·right가 모두 나온다. 모르는 값은 가운데로 둔다.
            horizontalAlign: TextAlignment(rawValue: object["horizontalalign"] as? String ?? "")
                ?? .center,
            verticalAlign: TextVerticalAlignment(
                rawValue: object["verticalalign"] as? String ?? "") ?? .center,
            // limitwidth가 꺼져 있으면 maxwidth가 있어도 줄바꿈하지 않는다.
            wrapping: TextWrapping(
                maxWidth: (boolValue(object["limitwidth"]) ?? false)
                    ? (doubleValue(object["maxwidth"]) ?? 0) : 0,
                maxRows: (boolValue(object["limitrows"]) ?? false)
                    ? Int(doubleValue(object["maxrows"]) ?? 0) : 0,
                usesEllipsis: boolValue(object["limituseellipsis"]) ?? false,
                pointSize: doubleValue(object["pointsize"]) ?? 0),
            shadow: (boolValue(object["dropshadow"]) ?? false)
                ? TextShadow(
                    color: (object["dropshadowcolor"] as? String).flatMap(Vec3.parse)
                        ?? Vec3(x: 0, y: 0, z: 0),
                    offset: (object["dropshadowoffset"] as? String).flatMap(Vec2.parse)
                        ?? Vec2(x: 0, y: 0),
                    blur: doubleValue(object["dropshadowsize"]) ?? 0,
                    opacity: Swift.min(Swift.max(
                        doubleValue(object["dropshadowopacity"]) ?? 1, 0), 1))
                : nil)
    }

    /// 파티클 프리셋을 따라가 레이어 내용을 판정한다.
    static func resolveParticleContent(
        presetPath: String, resolver: ReferenceResolver, override: ParticleOverride
    ) -> LayerContent {
        // 프리셋 JSON을 읽는다
        guard let presetJson = resolver.json(for: presetPath) else {
            return .unsupported(reason: "파티클 프리셋을 찾을 수 없다: \(presetPath)")
        }

        // 프리셋을 파싱한다
        guard let preset = ParticlePreset.parse(presetJson) else {
            return .unsupported(reason: "파티클 프리셋 파싱 실패: \(presetPath)")
        }

        // 프리셋의 머티리얼 경로를 따라 머티리얼을 읽는다
        guard let material = resolver.json(for: preset.materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let pass = passes.first else {
            return .unsupported(reason: "파티클 머티리얼을 찾을 수 없다: \(preset.materialPath)")
        }

        // 첫 텍스처 이름을 얻는다
        guard let textures = pass["textures"] as? [Any],
              let textureName = textures.first as? String else {
            return .unsupported(reason: "파티클 머티리얼의 첫 텍스처가 없다: \(preset.materialPath)")
        }

        // **굴절 파티클**은 색이 아니라 **배경을 휘게 하는 렌즈**다. 함께 선언된
        // 노멀맵으로 뒤 그림을 밀어 읽어야 유리에 맺힌 물방울로 보인다.
        // 그냥 그리면 텍스처가 흰 덩어리라 불투명한 흰 점이 뜬다(실물 확인).
        //
        // 조건 둘을 **함께** 본다. 실물에서 하나만 보면 틀린다:
        // - `REFRACT`가 **켜져 있어야** 한다. `magic_vortex_0`은 값이 0이다.
        // - **노멀맵이 함께 와야** 한다. 굴절은 그것 없이 성립하지 않는다.
        //   창작마당 `leaves1`은 `REFRACT: 1`인데 텍스처가 꽃 하나뿐이라
        //   그냥 스프라이트다 — 이걸 렌즈로 다루면 꽃잎이 사라진다.
        let refractOn = ((pass["combos"] as? [String: Any])?["REFRACT"] as? NSNumber)?
            .intValue ?? 0
        let normalPath: String? = {
            guard refractOn != 0, textures.count >= 2,
                  let name = textures[1] as? String, !name.isEmpty else { return nil }
            return "materials/\(name).tex"
        }()
        // 미는 정도는 재질이 정한다. 셰이더 주석의 기본값이 0.05이고,
        // 실물 유리창 비는 -0.1이다(음수면 반대로 민다). 여기가 곧 굴절의
        // 세기라, 놓치면 물방울이 배경을 거의 안 휘거나 화면을 뭉갠다.
        let refractAmount: Double = {
            let values = pass["constantshadervalues"] as? [String: Any] ?? [:]
            let raw = (values["ui_editor_properties_refract_amount"] as? [String: Any])?["value"]
                ?? values["ui_editor_properties_refract_amount"]
            guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { return 0.05 }
            return Swift.min(Swift.max(value, -1), 1)
        }()

        // 합성 방식. 없으면 씬 머티리얼의 기본값인 translucent다.
        // additive만 특별 취급하는 이유는 실물에서 이 둘만 나오기 때문이다.
        let blend: ParticleBlendMode =
            (pass["blending"] as? String) == "additive" ? .additive : .translucent

        // 텍스처 경로를 만든다
        let texturePath = "materials/\(textureName).tex"
        // 자식 프리셋을 읽어 붙인다. 여기가 참조 해석기가 있는 유일한 자리다.
        let withChildren = preset.withChildren(
            resolveParticleChildren(preset.childReferences, resolver: resolver, depth: 0))
        return .particle(preset: withChildren.applying(override),
                         texturePath: texturePath, blend: blend, normalPath: normalPath,
                         refractAmount: refractAmount)
    }

    /// 자식 프리셋을 재귀로 읽는다.
    ///
    /// 실물에서 두 단계면 충분하다(`rain_screen_4k` → `rain_screen_fast_4k` →
    /// `rain_screen_fast_child`). 깊이를 막아 두면 서로를 가리키는 파일이 와도
    /// 여기서 멈춘다 — 창작마당 파일은 신뢰할 수 없는 입력이다.
    static let maxParticleChildDepth = 2

    static func resolveParticleChildren(
        _ references: [ParticleChildReference], resolver: ReferenceResolver, depth: Int
    ) -> [ParticleChild] {
        guard depth < maxParticleChildDepth else { return [] }
        var out: [ParticleChild] = []
        for reference in references {
            guard let json = resolver.json(for: reference.name),
                  let child = ParticlePreset.parse(json),
                  let material = resolver.json(for: child.materialPath),
                  let passes = material["passes"] as? [[String: Any]],
                  let pass = passes.first,
                  let textures = pass["textures"] as? [Any],
                  let textureName = textures.first as? String
            else { continue }
            // 굴절 자식도 부모와 같은 길로 그린다. 불꽃이 터질 때의 충격파가
            // 이것이라, 건너뛰면 폭발에서 일그러짐만 빠진다.
            let refractOn = ((pass["combos"] as? [String: Any])?["REFRACT"] as? NSNumber)?
                .intValue ?? 0
            let childNormal: String? = {
                guard refractOn != 0, textures.count >= 2,
                      let name = textures[1] as? String, !name.isEmpty else { return nil }
                return "materials/\(name).tex"
            }()
            let childRefract: Double = {
                let values = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let raw = (values["ui_editor_properties_refract_amount"]
                    as? [String: Any])?["value"]
                    ?? values["ui_editor_properties_refract_amount"]
                guard let value = (raw as? NSNumber)?.doubleValue,
                      value.isFinite else { return 0.05 }
                return Swift.min(Swift.max(value, -1), 1)
            }()
            let blend: ParticleBlendMode =
                (pass["blending"] as? String) == "additive" ? .additive : .translucent
            let nested = resolveParticleChildren(
                child.childReferences, resolver: resolver, depth: depth + 1)
            out.append(ParticleChild(
                reference: reference,
                preset: child.withChildren(nested),
                texturePath: "materials/\(textureName).tex",
                blend: blend, normalPath: childNormal, refractAmount: childRefract))
        }
        return out
    }

    /// 우리 쿼드 경로가 그대로 그려도 되는 표준 이미지 셰이더들. 실물 설치 씬
    /// 15개에서 이미지 재질 64개 중 55개가 이 가족이다. 그 밖(`ps2menu` 9개)은
    /// 재질의 셰이더로 그려야 한다.
    static let plainImageShaders: Set<String> = [
        "genericimage", "genericimage2", "genericimage3", "genericimage4",
        "flat", "composelayer", "passthrough", "genericimage_hdr",
    ]

    /// 머티리얼을 읽어 이 레이어가 무엇인지 판정한다.
    private static func resolveContent(
        modelPath: String, object: [String: Any], resolver: ReferenceResolver
    ) -> LayerContent {
        guard let model = resolver.json(for: modelPath),
              let materialPath = model["material"] as? String,
              let material = resolver.json(for: materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let pass = passes.first else {
            return .unsupported(reason: "참조를 따라갈 수 없다: \(modelPath)")
        }

        let textures = pass["textures"] as? [Any]
        // 셰이더 flat이면서 텍스처가 없을 때만 단색이다. 실물 solidlayer가 그 모양이다.
        // OR로 쓰면 flat + _rt_ 조합이 렌더 타깃 검사에 닿지 못하고 삼켜지고,
        // textures가 없는 다른 셰이더도 전부 단색이 되어버린다. 반드시 AND다.
        // 재질이 자기 셰이더를 가지면 텍스처를 붙이는 게 아니라 셰이더가 그림을
        // 만든다. 실물 원근 씬의 배경 구름(`ps2menu`)이 그렇다 — 보통 이미지로
        // 그리면 셰이더의 입력 잡음이 그대로 보인다. 표준 이미지 셰이더 가족은
        // 우리 쿼드 경로가 이미 같은 일을 하므로 그대로 둔다.
        if let shader = pass["shader"] as? String, !Self.plainImageShaders.contains(shader) {
            let name = (textures?.first as? String) ?? ""
            return .shadedImage(materialPath: materialPath,
                                texturePath: name.isEmpty ? "" : "materials/\(name).tex")
        }
        if (pass["shader"] as? String) == "flat", textures == nil {
            let color = (object["color"] as? String).flatMap(Vec3.parse)
                ?? Vec3(x: 1, y: 1, z: 1)
            return .solidColor(color)
        }
        guard let name = textures?.first as? String else {
            return .unsupported(reason: "머티리얼의 첫 텍스처가 없다: \(materialPath)")
        }
        // _rt_ 접두는 파일이 아니라 렌더 타깃이다.
        if name.hasPrefix("_rt_") {
            // 화면 전체 버퍼는 우리가 줄 수 있다 — 그 지점까지 합성된 화면이다.
            // 오디오 막대가 이 형태로 배경 위에 막대를 그린다.
            if name == "_rt_FullFrameBuffer" { return .composition }
            return .unsupported(reason: "아직 모르는 렌더 타깃이다: \(name)")
        }
        return .image(texturePath: "materials/\(name).tex")
    }
}
