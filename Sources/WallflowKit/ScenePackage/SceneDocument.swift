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
    public let clearEnabled: Bool
    public let layers: [SceneLayer]

    public static func load(from reader: PkgReader) throws -> SceneDocument {
        try load(from: reader, assets: nil)
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
        from reader: PkgReader, assets: AssetsStore?
    ) throws -> SceneDocument {
        let raw = try reader.data(for: Self.sceneEntryName(in: reader))
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }

        let general = root["general"] as? [String: Any] ?? [:]
        // 키는 있는데 값이 null이면 직교가 아니라 원근 투영 씬이다.
        // 값이 없는 것과 형태가 다른 것을 구분해야 진단이 맞다.
        if general.keys.contains("orthogonalprojection"),
           !(general["orthogonalprojection"] is [String: Any]) {
            throw SceneError.perspectiveProjectionUnsupported
        }
        guard let ortho = general["orthogonalprojection"] as? [String: Any],
              let width = ortho["width"] as? Int,
              let height = ortho["height"] as? Int,
              width > 0, height > 0 else {
            throw SceneError.missingField("orthogonalprojection")
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
        let layers = objects.enumerated().map { index, object in
            let id = object["id"] as? Int ?? index
            return makeLayer(object, fallbackID: index, resolver: resolver,
                             transform: transforms[id] ?? .identity)
        }

        return SceneDocument(
            orthoWidth: width, orthoHeight: height,
            clearColor: clearColor, clearEnabled: clearEnabled,
            layers: layers
        )
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
            // 실물의 가장 깊은 사슬이 3단이다. 32면 충분히 관대하면서도 고리를 끊는다.
            for _ in 0..<32 {
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
        _ object: [String: Any], fallbackID: Int, resolver: ReferenceResolver,
        transform: LayerTransform
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

        // origin/size가 문자열이 아니라 {"script": ..., "value": ...} 객체인 씬이 있다.
        // 그 객체에도 `value`가 있고 그게 편집기에서 마지막으로 정해진 좌표다.
        // 스크립트를 아직 못 돌려도 이 값으로 제자리에 그릴 수 있다 —
        // 실물 씬 하나는 origin 스크립트의 update가 통째로 주석 처리돼 있어
        // `value`가 유일한 좌표다.
        // 부모 사슬을 합친 화면 좌표를 쓴다. 자체 origin은 부모 안의 상대값이다.
        // 자체 좌표가 읽히지 않으면(NaN 포함) 레이어를 버린다 — 합친 값이 0이 되어
        // 화면 한복판에 그려지면 파일이 이상한 것을 정상처럼 보이게 한다.
        let ownOriginParsed = Self.scalarOrScripted(object["origin"]).flatMap(Vec3.parse) != nil
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
        var displayScripts: [String] = []
        for key in ["origin", "size", "scale", "alpha", "color", "visible"] {
            guard let script = (object[key] as? [String: Any])?["script"] as? String
            else { continue }
            // alpha와 visible 스크립트는 실제로 돌린다. 미디어 위젯이 여기서
            // "지금 재생 중이 아니다"를 알고 스스로 숨는다.
            if key == "alpha" || key == "visible" {
                displayScripts.append(script)
            } else {
                unrun.append(key)
            }
        }

        func unsupported(_ reason: String) -> SceneLayer {
            SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .unsupported(reason: reason), unrunScripts: unrun,
                alpha: alpha, tint: tint, rotation: rotation,
                displayScripts: displayScripts
            )
        }

        if let particlePresetPath = object["particle"] as? String {
            guard let origin else {
                return unsupported("파티클 레이어지만 origin이 스크립트다. 스크립팅은 M5에서 지원한다")
            }
            let particleSize = (object["size"] as? String).flatMap(Vec2.parse)
                ?? Vec2(x: 0, y: 0)
            let content = resolveParticleContent(presetPath: particlePresetPath, resolver: resolver)
            return SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin, size: particleSize,
                content: content, unrunScripts: unrun, alpha: alpha, tint: tint, rotation: rotation,
                displayScripts: displayScripts
            )
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
                    displayScripts: displayScripts)
            }
            if let sound = makeSoundLayer(object) {
                // 소리는 화면을 차지하지 않는다. origin이 없어도 상관없다.
                return SceneLayer(
                    id: id, name: name, visible: visible,
                    origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                    size: size ?? Vec2(x: 0, y: 0),
                    content: .sound(sound), unrunScripts: unrun,
                    alpha: alpha, tint: tint, rotation: rotation,
                    displayScripts: displayScripts)
            }
            if object["sound"] != nil { return unsupported("소리 파일 목록을 읽지 못했다") }
            // 도형 레이어. 실물에서 빛줄기(Rayons lumineux)가 이 형태인데,
            // 도형 자체가 아니라 거기 붙은 이펙트가 그림을 만든다.
            if object["shape"] != nil {
                return unsupported("도형 레이어라 M6의 이펙트 체인이 필요하다")
            }
            return unsupported("알 수 없는 레이어 종류")
        }
        guard let origin, let size else {
            // origin과 size가 아예 없고 effects만 있으면 후처리 레이어다.
            // 실물 "Couche de post-traitement"가 이 경우인데, 스크립트 탓이라고
            // 말하면 사용자를 엉뚱한 원인으로 보낸다.
            if object["origin"] == nil, object["size"] == nil, object["effects"] != nil {
                return unsupported("화면 전체에 거는 후처리 레이어라 M6의 이펙트 체인이 필요하다")
            }
            return unsupported("origin이나 size를 읽을 수 없다")
        }

        let content = resolveContent(modelPath: modelPath, object: object, resolver: resolver)
        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: content, unrunScripts: unrun, alpha: alpha, tint: tint,
            rotation: rotation, displayScripts: displayScripts
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
            scriptProperties: properties)
    }

    /// 파티클 프리셋을 따라가 레이어 내용을 판정한다.
    private static func resolveParticleContent(
        presetPath: String, resolver: ReferenceResolver
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

        // 합성 방식. 없으면 씬 머티리얼의 기본값인 translucent다.
        // additive만 특별 취급하는 이유는 실물에서 이 둘만 나오기 때문이다.
        let blend: ParticleBlendMode =
            (pass["blending"] as? String) == "additive" ? .additive : .translucent

        // 텍스처 경로를 만든다
        let texturePath = "materials/\(textureName).tex"
        return .particle(preset: preset, texturePath: texturePath, blend: blend)
    }

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
        if (pass["shader"] as? String) == "flat", textures == nil {
            let color = (object["color"] as? String).flatMap(Vec3.parse)
                ?? Vec3(x: 1, y: 1, z: 1)
            return .solidColor(color)
        }
        guard let name = textures?.first as? String else {
            return .unsupported(reason: "머티리얼의 첫 텍스처가 없다: \(materialPath)")
        }
        // _rt_ 접두는 파일이 아니라 렌더 타깃이다. FBO 체인이 필요하다.
        if name.hasPrefix("_rt_") {
            return .unsupported(reason: "렌더 타깃 참조라 M6의 이펙트 체인이 필요하다: \(name)")
        }
        return .image(texturePath: "materials/\(name).tex")
    }
}
