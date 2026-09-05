import Foundation

public enum SceneError: Error, Equatable {
    case malformedSceneJSON
    case missingField(String)
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

    public static func load(
        from reader: PkgReader, assets: AssetsStore?
    ) throws -> SceneDocument {
        let raw = try reader.data(for: "scene.json")
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }

        let general = root["general"] as? [String: Any] ?? [:]
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
        let layers = objects.enumerated().map { index, object in
            makeLayer(object, fallbackID: index, resolver: resolver)
        }

        return SceneDocument(
            orthoWidth: width, orthoHeight: height,
            clearColor: clearColor, clearEnabled: clearEnabled,
            layers: layers
        )
    }

    /// 레이어 하나가 해석되지 않아도 씬 전체를 버리지 않는다.
    /// 그릴 수 없는 것은 이유를 달아 unsupported로 남긴다.
    private static func makeLayer(
        _ object: [String: Any], fallbackID: Int, resolver: ReferenceResolver
    ) -> SceneLayer {
        let id = object["id"] as? Int ?? fallbackID
        let name = object["name"] as? String ?? "object\(fallbackID)"
        let visible = object["visible"] as? Bool ?? true

        // origin/size가 문자열이 아니라 {"script": ..., "value": ...} 객체인 씬이 있다.
        // 그 객체에도 `value`가 있고 그게 편집기에서 마지막으로 정해진 좌표다.
        // 스크립트를 아직 못 돌려도 이 값으로 제자리에 그릴 수 있다 —
        // 실물 씬 하나는 origin 스크립트의 update가 통째로 주석 처리돼 있어
        // `value`가 유일한 좌표다.
        let origin = Self.scalarOrScripted(object["origin"]).flatMap(Vec3.parse)
        let size = Self.scalarOrScripted(object["size"]).flatMap(Vec2.parse)
        // 스크립트가 붙어 있는데 우리가 못 돌리는 경우를 사용자에게 알린다.
        var unrun: [String] = []
        for key in ["origin", "size", "scale", "alpha", "color", "visible"]
        where (object[key] as? [String: Any])?["script"] != nil {
            unrun.append(key)
        }

        func unsupported(_ reason: String) -> SceneLayer {
            SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .unsupported(reason: reason), unrunScripts: unrun
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
                content: content, unrunScripts: unrun
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
                    unrunScripts: unrun)
            }
            if object["sound"] != nil { return unsupported("사운드는 M6에서 지원한다") }
            return unsupported("알 수 없는 레이어 종류")
        }
        guard let origin, let size else {
            return unsupported("origin이나 size가 스크립트다. 스크립팅은 M5에서 지원한다")
        }

        let content = resolveContent(modelPath: modelPath, object: object, resolver: resolver)
        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: content, unrunScripts: unrun
        )
    }

    /// 문자열이거나, `{"script": ..., "value": ...}` 객체면 그 `value`.
    private static func scalarOrScripted(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        return (raw as? [String: Any])?["value"] as? String
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
