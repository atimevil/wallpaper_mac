import XCTest
@testable import WallflowKit

/// 씬 단위 스크립트 호스트. 실물 원근 씬이 요구하는 것들 — 레이어 사이의 `shared`,
/// `createLayer`, 카메라 변환, 속성별 `update(value)` — 을 하나씩 확인한다.
final class SceneScriptHostTests: XCTestCase {
    private func seed(_ id: Int, _ name: String, visible: Bool = true,
                      origin: Vec3 = Vec3(x: 0, y: 0, z: 0),
                      scripts: [LayerScript]) -> SceneScriptHost.LayerSeed {
        SceneScriptHost.LayerSeed(
            id: id, name: name, origin: origin, angles: Vec3(x: 0, y: 0, z: 0),
            scale: Vec3(x: 1, y: 1, z: 1), alpha: 1, visible: visible, scripts: scripts)
    }

    /// 한 레이어가 `shared`에 올린 클래스를 **뒤의** 레이어가 쓴다. 실물 OMGMatrix가 이 꼴이다.
    func testSharedObjectCrossesLayers() {
        let host = SceneScriptHost(layers: [
            seed(1, "lib", visible: false, scripts: [LayerScript(
                property: "visible",
                source: "class M { static two() { return 2; } }\nshared.M = M;")]),
            seed(2, "user", scripts: [LayerScript(
                property: "alpha",
                source: "let M = shared.M;\nexport function update(v) { return v / M.two(); }")]),
        ], camera: nil)
        XCTAssertEqual(host.unitCount, 2)
        let snap = host.tick(frametime: 1 / 60)
        XCTAssertEqual(snap.failures, [])
        XCTAssertEqual(snap.layers[2]?.alpha, 0.5)
    }

    /// 스크립트마다 자기 범위가 있다. 둘 다 `update`를 정의해도 서로 덮어쓰지 않는다.
    func testScriptsDoNotClobberEachOther() {
        let host = SceneScriptHost(layers: [
            seed(1, "a", scripts: [LayerScript(property: "alpha",
                                               source: "export function update(v) { return 0.25; }")]),
            seed(2, "b", scripts: [LayerScript(property: "alpha",
                                               source: "export function update(v) { return 0.75; }")]),
        ], camera: nil)
        let snap = host.tick(frametime: 0.1)
        XCTAssertEqual(snap.layers[1]?.alpha, 0.25)
        XCTAssertEqual(snap.layers[2]?.alpha, 0.75)
    }

    /// 실물 프리즘 스크립트의 뼈대: 자산을 등록하고 레이어를 만들어 자리를 옮긴다.
    func testCreateLayerFromRegisteredAssetAndMoveIt() {
        let source = """
        const asset = engine.registerAsset("models/prism/prism.mdl");
        let layers = [];
        export function init(value) {
            for (let i = 0; i < 3; i++) {
                let l = thisScene.createLayer(asset);
                l.name = "prism " + i;
                l.scale = new Vec3(0, 0, 0);
                layers.push(l);
            }
            return value;
        }
        export function update(value) {
            for (let i = 0; i < layers.length; i++) {
                layers[i].origin = new Vec3(i * 10, 0, 0);
                layers[i].angles = new Vec3(0, engine.runtime * 20, 0);
                layers[i].scale = new Vec3(0.9, 0.9, 0.9);
            }
            return value;
        }
        """
        let host = SceneScriptHost(layers: [
            seed(12, "Prisms (script)", visible: false,
                 scripts: [LayerScript(property: "visible", source: source)]),
        ], camera: SceneCamera())
        let snap = host.tick(frametime: 0.5)
        XCTAssertEqual(snap.failures, [])
        let spawned = snap.order.filter { $0 < 0 }
        XCTAssertEqual(spawned.count, 3)
        XCTAssertEqual(snap.layers[spawned[1]]?.asset, "models/prism/prism.mdl")
        XCTAssertEqual(snap.layers[spawned[1]]?.origin, Vec3(x: 10, y: 0, z: 0))
        XCTAssertEqual(snap.layers[spawned[1]]?.angles.y ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(snap.layers[spawned[1]]?.name, "prism 1")
        // 문서 레이어는 그대로 숨어 있다 — 스크립트가 value를 그대로 돌려줬다.
        XCTAssertEqual(snap.layers[12]?.visible, false)
    }

    /// 실물 카메라 스크립트: init에서 center를, update에서 eye를 옮긴다.
    func testCameraTransformsRoundTrip() {
        let source = """
        export function init(value) {
            let c = thisScene.getCameraTransforms();
            c.center = new Vec3(0, 0, 0);
            thisScene.setCameraTransforms(c);
            return value;
        }
        export function update(value) {
            let c = thisScene.getCameraTransforms();
            c.eye = c.eye.add(new Vec3(0, 0, -10));
            thisScene.setCameraTransforms(c);
            return value;
        }
        """
        var camera = SceneCamera()
        camera.eye = Vec3(x: 0, y: 0, z: 250)
        camera.center = Vec3(x: 5, y: 5, z: 5)
        let host = SceneScriptHost(layers: [
            seed(1, "Camera (script)", visible: false,
                 scripts: [LayerScript(property: "visible", source: source)]),
        ], camera: camera)
        let first = host.tick(frametime: 1 / 60)
        XCTAssertEqual(first.camera?.eye, Vec3(x: 0, y: 0, z: 240))
        XCTAssertEqual(first.camera?.center, Vec3(x: 0, y: 0, z: 0))
        let second = host.tick(frametime: 1 / 60)
        XCTAssertEqual(second.camera?.eye, Vec3(x: 0, y: 0, z: 230))
        // fov는 스크립트가 못 건드린다. 문서 값이 남는다.
        XCTAssertEqual(second.camera?.fov, 50)
    }

    /// 카메라를 건드리지 않은 틱은 camera가 nil이다 — 호출자가 매 프레임 덮어쓰지 않게.
    func testUntouchedCameraIsNil() {
        let host = SceneScriptHost(layers: [
            seed(1, "a", scripts: [LayerScript(property: "alpha",
                                               source: "export function update(v) { return v; }")]),
        ], camera: SceneCamera())
        XCTAssertNil(host.tick(frametime: 0.1).camera)
    }

    /// `update(value)`는 속성의 현재 값을 받는다. origin 스크립트는 Vec3를 받고 돌려준다.
    func testOriginScriptReceivesAndReturnsVec3() {
        let host = SceneScriptHost(layers: [
            seed(7, "mover", origin: Vec3(x: 1, y: 2, z: 3), scripts: [LayerScript(
                property: "origin",
                source: "export function update(v) { return v.add(new Vec3(0, 0, engine.frametime * 100)); }")]),
        ], camera: nil)
        let snap = host.tick(frametime: 0.5)
        XCTAssertEqual(snap.layers[7]?.origin, Vec3(x: 1, y: 2, z: 53))
        XCTAssertEqual(host.tick(frametime: 0.5).layers[7]?.origin, Vec3(x: 1, y: 2, z: 103))
    }

    /// 텍스트 스크립트는 문자열을 돌려주고, 상한을 넘으면 잘린다.
    func testTextScriptAndLengthCap() {
        let host = SceneScriptHost(layers: [
            SceneScriptHost.LayerSeed(
                id: 3, name: "clock", origin: Vec3(x: 0, y: 0, z: 0),
                angles: Vec3(x: 0, y: 0, z: 0), scale: Vec3(x: 1, y: 1, z: 1),
                alpha: 1, visible: true, text: "00:00",
                scripts: [LayerScript(property: "text",
                                      source: "export function update(v) { return v + '!'.repeat(10000); }")]),
        ], camera: nil)
        let text = host.tick(frametime: 1).layers[3]?.text
        XCTAssertEqual(text?.count, SceneScriptHost.maxTextLength)
        XCTAssertTrue(text?.hasPrefix("00:00!") ?? false)
    }

    /// 사용자 속성은 init 뒤 `applyUserProperties`로 들어가고, 색은 Vec3다.
    func testApplyUserPropertiesReceivesTypedValues() {
        let source = """
        let seen = null;
        export function applyUserProperties(p) { seen = p; }
        export function update(v) {
            if (!seen) return 0;
            return (seen.fov === 53 && seen.on === true && seen.tint.z === 0.5 && seen.label === 'hi') ? 1 : 0.1;
        }
        """
        let host = SceneScriptHost(
            layers: [seed(1, "a", scripts: [LayerScript(property: "alpha", source: source)])],
            camera: nil,
            userProperties: ["fov": .number(53), "on": .toggle(true),
                             "tint": .color(Vec3(x: 1, y: 0, z: 0.5)), "label": .text("hi")])
        XCTAssertEqual(host.tick(frametime: 0.1).layers[1]?.alpha, 1)
    }

    /// `resizeScreen`이 화면 크기와 함께 불린다. 실물이 여기서 origin을 화면 비율에 맞춘다.
    func testResizeScreenIsCalledWithScreenResolution() {
        let host = SceneScriptHost(layers: [
            seed(1, "a", scripts: [LayerScript(
                property: "visible",
                source: "export function resizeScreen(s) { thisLayer.origin = new Vec3(s.x / s.y, 0, 0); }")]),
        ], camera: nil, environment: .init(screenWidth: 3200, screenHeight: 1600))
        XCTAssertEqual(host.tick(frametime: 0).layers[1]?.origin.x, 2)
    }

    /// 실물 미디어 위젯: "재생 중이 아니다"를 듣고 스스로 숨는다.
    func testMediaCallbacksHideWidget() {
        let host = SceneScriptHost(layers: [
            seed(1, "cover", scripts: [LayerScript(
                property: "alpha",
                source: """
                export function mediaPlaybackChanged(event) {
                    thisLayer.alpha = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED ? 1 : 0;
                }
                """)]),
        ], camera: nil)
        XCTAssertEqual(host.tick(frametime: 0).layers[1]?.alpha, 0)
    }

    /// 스크립트 하나가 깨져도 나머지는 돈다. 깨진 것은 이유가 남는다.
    func testBrokenScriptIsIsolated() {
        let host = SceneScriptHost(layers: [
            seed(1, "broken", scripts: [LayerScript(property: "alpha",
                                                    source: "function update( { syntax")]),
            seed(2, "throws", scripts: [LayerScript(property: "alpha",
                                                    source: "export function update(v) { throw new Error('boom'); }")]),
            seed(3, "fine", scripts: [LayerScript(property: "alpha",
                                                  source: "export function update(v) { return 0.5; }")]),
        ], camera: nil)
        XCTAssertEqual(host.unitCount, 2)
        let snap = host.tick(frametime: 0.1)
        XCTAssertEqual(snap.layers[3]?.alpha, 0.5)
        XCTAssertEqual(snap.layers[2]?.alpha, 1, "예외를 낸 스크립트는 값을 못 바꾼다")
        XCTAssertTrue(snap.failures.contains { $0.hasPrefix("broken.alpha") })
        XCTAssertTrue(snap.failures.contains { $0.hasPrefix("throws.alpha") && $0.contains("boom") })
        // 연달아 실패한 스크립트는 조용해진다.
        _ = host.tick(frametime: 0.1)
        _ = host.tick(frametime: 0.1)
        XCTAssertEqual(host.tick(frametime: 0.1).failures, [])
    }

    /// 만들 수 있는 레이어 수에는 상한이 있다. 넘치면 화면에 안 붙는 객체를 준다 —
    /// 스크립트는 죽지 않고, 스냅숏에는 상한만큼만 있다.
    func testSpawnCapReturnsDetachedLayers() {
        let source = """
        const a = engine.registerAsset("particles/x.json");
        export function update(v) {
            for (let i = 0; i < 300; i++) { let l = thisScene.createLayer(a); l.name = "x"; }
            return v;
        }
        """
        let host = SceneScriptHost(layers: [
            seed(1, "spam", scripts: [LayerScript(property: "visible", source: source)]),
        ], camera: nil)
        let snap = host.tick(frametime: 0.1)
        XCTAssertEqual(snap.failures, [])
        XCTAssertEqual(snap.order.filter { $0 < 0 }.count, SceneScriptHost.maxSpawnedLayers)
        XCTAssertEqual(host.tick(frametime: 0.1).order.filter { $0 < 0 }.count,
                       SceneScriptHost.maxSpawnedLayers)
    }

    /// `getLayer(name)`으로 문서 레이어를 잡아 옮긴다. 실물이 `mainPrism`을 이렇게 잡는다.
    func testGetLayerByNameMovesDocumentLayer() {
        let host = SceneScriptHost(layers: [
            seed(1, "driver", scripts: [LayerScript(
                property: "visible",
                source: "export function update(v) { thisScene.getLayer('mainPrism').origin = new Vec3(1, 2, 3); return v; }")]),
            seed(104, "mainPrism", scripts: []),
        ], camera: nil)
        XCTAssertEqual(host.tick(frametime: 0.1).layers[104]?.origin, Vec3(x: 1, y: 2, z: 3))
    }

    /// 소리 레이어의 play/stop/volume이 스냅숏에 실린다.
    func testSoundControlsAreReported() {
        let host = SceneScriptHost(layers: [
            SceneScriptHost.LayerSeed(
                id: 9, name: "noise", origin: Vec3(x: 0, y: 0, z: 0),
                angles: Vec3(x: 0, y: 0, z: 0), scale: Vec3(x: 1, y: 1, z: 1),
                alpha: 1, visible: true, playing: false, volume: 0.4,
                scripts: [LayerScript(property: "origin",
                                      source: "export function update(v) { thisLayer.play(); thisLayer.volume = 0.2; return v; }")]),
        ], camera: nil)
        let state = host.tick(frametime: 0.1).layers[9]
        XCTAssertEqual(state?.playing, true)
        XCTAssertEqual(state?.volume, 0.2)
    }

    /// 빌더 기본값을 레이어의 `scriptproperties`가 이긴다. 실물 시계의 구분자가 이것이다.
    func testScriptPropertiesOverrideBuilderDefaults() {
        let source = """
        let scriptProperties = createScriptProperties()
            .addText({ name: 'delimiter', value: '-' })
            .finish();
        export function update(v) { return '12' + scriptProperties.delimiter + '34'; }
        """
        let host = SceneScriptHost(layers: [
            SceneScriptHost.LayerSeed(
                id: 1, name: "clock", origin: Vec3(x: 0, y: 0, z: 0),
                angles: Vec3(x: 0, y: 0, z: 0), scale: Vec3(x: 1, y: 1, z: 1),
                alpha: 1, visible: true, text: "",
                scripts: [LayerScript(property: "text", source: source,
                                      scriptProperties: ["delimiter": .text(":")])]),
        ], camera: nil)
        XCTAssertEqual(host.tick(frametime: 1).layers[1]?.text, "12:34")
    }

    /// 재질 상수 스크립트: `update`가 상수를 바꾸고 `applyUserProperties`가 `thisObject`에 색을 쓴다.
    /// 실물 프리즘 재질의 Alpha(`shared.fade`)와 start_color가 이 모양이다.
    func testMaterialScriptsUpdateConstants() {
        var seed = seed(5, "prism", scripts: [LayerScript(
            property: "visible", source: "shared.fade = 0.25;\nexport function update(v) { return v; }")])
        seed.materialScripts = [
            .init(key: "Alpha", source: "export function update(value) { return shared.fade; }",
                  value: .scalar(1)),
            .init(key: "start_color", source: """
                export function applyUserProperties(p) {
                    if (p.prism_gradient_1 != undefined) { thisObject.start_color = p.prism_gradient_1.copy(); }
                }
                """, value: .vector([0.48, 0.33, 0.78])),
            .init(key: "Light", source: "export function update(value) { return value + 0.5; }",
                  value: .scalar(0)),
        ]
        let host = SceneScriptHost(layers: [seed], camera: nil,
                                   userProperties: ["prism_gradient_1": .color(Vec3(x: 1, y: 0, z: 0))])
        let snap = host.tick(frametime: 0.1)
        XCTAssertEqual(snap.failures, [])
        let material = snap.layers[5]?.material ?? [:]
        XCTAssertEqual(material["Alpha"], .scalar(0.25))
        XCTAssertEqual(material["start_color"], .vector([1, 0, 0]))
        XCTAssertEqual(material["Light"], .scalar(0.5))
        XCTAssertEqual(host.tick(frametime: 0.1).layers[5]?.material["Light"], .scalar(1.0))
    }

    /// 스크립트가 만든 레이어의 재질 스크립트를 뒤늦게 붙인다. 붙은 것만 init을 돈다.
    func testAttachMaterialScriptsToSpawnedLayer() {
        let source = """
        const a = engine.registerAsset("models/p.mdl");
        export function init(v) { thisScene.createLayer(a); return v; }
        export function update(v) { return v; }
        """
        let host = SceneScriptHost(layers: [
            seed(1, "spawner", scripts: [LayerScript(property: "visible", source: source)]),
        ], camera: nil, userProperties: ["k": .number(3)])
        let spawned = host.tick(frametime: 0).order.first { $0 < 0 }
        XCTAssertNotNil(spawned)
        host.attachMaterialScripts(layerID: spawned ?? 0, [
            .init(key: "Alpha", source: """
                let base = 0;
                export function init(v) { base = v; }
                export function applyUserProperties(p) { base += p.k; }
                export function update(v) { return base; }
                """, value: .scalar(1)),
        ])
        let snap = host.tick(frametime: 0.1)
        XCTAssertEqual(snap.failures, [])
        XCTAssertEqual(snap.layers[spawned ?? 0]?.material["Alpha"], .scalar(4))
    }

    /// `engine.registerAudioBuffers`: 요청한 뒤에야 `wantsAudio`가 켜지고, 틱마다 채워진다.
    /// 실물 앨범 표지가 `audioBuffer.average`로 크기를 흔든다.
    func testAudioBuffersAreFilledEachTick() {
        let source = """
        const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        export function update(v) { return audioBuffer.average + audioBuffer.left[1] * 10; }
        """
        let host = SceneScriptHost(layers: [
            seed(1, "cover", scripts: [LayerScript(property: "alpha", source: source)]),
        ], camera: nil)
        XCTAssertTrue(host.wantsAudio)
        let silent = host.tick(frametime: 0.1)
        XCTAssertEqual(silent.failures, [])
        XCTAssertEqual(silent.layers[1]?.alpha, 0)
        var left = [Float](repeating: 0, count: 16)
        left[1] = 0.05
        let loud = host.tick(frametime: 0.1, audio: [16: (left: left, right: [Float](repeating: 0.1, count: 16))])
        // average = (0.05 + 16 × 0.1) / 32 ≈ 0.0516, left[1] × 10 = 0.5
        XCTAssertEqual(loud.layers[1]?.alpha ?? 0, 0.5516, accuracy: 1e-4)
    }

    /// 오디오를 안 쓰는 씬은 `wantsAudio`가 꺼져 있다.
    func testNoAudioRequestMeansNoAudioWanted() {
        let host = SceneScriptHost(layers: [
            seed(1, "a", scripts: [LayerScript(property: "alpha", source: "export function update(v) { return v; }")]),
        ], camera: nil)
        XCTAssertFalse(host.wantsAudio)
        _ = host.tick(frametime: 0.1)
        XCTAssertFalse(host.wantsAudio)
    }

    /// `thisObject.pointsize`: 실물 시계가 `text_size` 사용자 속성으로 글자 크기를 정한다.
    func testPointSizeScriptChangesPointSize() {
        let source = """
        let size = 1;
        export function applyUserProperties(p) {
            if (p.text_size !== undefined) { size = p.text_size; thisObject.pointsize = size * 0.5; }
        }
        """
        var seed = SceneScriptHost.LayerSeed(
            id: 1, name: "clock", origin: Vec3(x: 0, y: 0, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
            scale: Vec3(x: 1, y: 1, z: 1), alpha: 1, visible: true, text: "12:00",
            scripts: [LayerScript(property: "text", source: source)])
        seed.pointSize = 35
        let host = SceneScriptHost(layers: [seed], camera: nil, userProperties: ["text_size": .number(50)])
        XCTAssertEqual(host.tick(frametime: 0).layers[1]?.pointSize, 25)
    }

    /// 모듈 import가 스크립트 범위 안에서 풀린다.
    func testModuleImportInsideUnit() {
        let host = SceneScriptHost(layers: [
            seed(1, "a", scripts: [LayerScript(
                property: "alpha",
                source: "import * as WEMath from 'WEMath';\nexport function update(v) { return WEMath.half(v); }")]),
        ], camera: nil, modules: ["WEMath": "export function half(x) { return x / 2; }"])
        XCTAssertEqual(host.tick(frametime: 0.1).layers[1]?.alpha, 0.5)
    }
}
