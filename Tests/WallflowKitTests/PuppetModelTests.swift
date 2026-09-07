import XCTest
import simd
@testable import WallflowKit

/// 퍼펫 워프 메시. 실물 셋의 바이트 배치를 그대로 흉내 낸 파일로 읽기와 스키닝을 확인한다.
final class PuppetModelTests: XCTestCase {
    private struct Builder {
        var data = Data()
        mutating func int(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func float(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        mutating func cstr(_ s: String) { data.append(contentsOf: Array(s.utf8)); data.append(0) }
        mutating func floats(_ vs: [Float]) { for v in vs { float(v) } }
    }

    /// 바인드 행렬(열 우선)을 자세에서 만든다.
    private func bindMatrix(x: Float, y: Float, rotation: Float, scale: Float = 1) -> [Float] {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return [c, s, 0, 0,  -s, c, 0, 0,  0, 0, 1, 0,  x, y, 0, 1]
    }

    /// 실물 배치의 퍼펫 파일 하나.
    private func makePuppet(
        vertices: [(pos: SIMD2<Float>, uv: SIMD2<Float>, bone: Int32, weight: Float, bone2: Int32, weight2: Float)],
        indices: [UInt16],
        bones: [(parent: Int32, matrix: [Float], json: String)],
        animation: (id: Int32, mode: String, fps: Float, frames: Int32,
                    tracks: [(bone: Int32, keys: [[Float]])])?
    ) -> Data {
        var b = Builder()
        b.cstr("MDLV0023")
        b.int(0x1800009); b.int(1); b.int(1)
        b.cstr("materials/a.json")
        b.int(0); b.floats([0, 0, 0, 0, 0, 0])
        b.int(0x180000F); b.int(Int32(vertices.count * 80))
        for v in vertices {
            b.floats([v.pos.x, v.pos.y, 0,  0, 0, 1,  1, 0, 0, 1])
            b.int(v.bone); b.int(v.bone2); b.int(0); b.int(0)
            b.floats([v.weight, v.weight2, 0, 0])
            b.floats([v.uv.x, v.uv.y])
        }
        b.int(Int32(indices.count * 2))
        for i in indices { withUnsafeBytes(of: i.littleEndian) { b.data.append(contentsOf: $0) } }
        // 실물처럼 길이가 제멋대로인 꼬리.
        b.data.append(contentsOf: [0, 1, 0x20, 0, 0, 0, 0])
        let skeletonAt = b.data.count
        b.cstr("MDLS0004")
        let animationOffsetAt = b.data.count
        b.int(0)                      // 나중에 채운다
        b.int(Int32(bones.count))
        for bone in bones {
            b.cstr("")
            b.int(1); b.int(bone.parent); b.int(64)
            b.floats(bone.matrix)
            b.cstr(bone.json)
        }
        // 보조 행렬 등. 읽지 않으므로 아무 바이트나 둔다.
        b.data.append(contentsOf: [UInt8](repeating: 0, count: 11) + [1] + [UInt8](repeating: 7, count: 76 * bones.count))
        let animationAt = b.data.count
        b.data.replaceSubrange(animationOffsetAt..<animationOffsetAt + 4,
                               with: withUnsafeBytes(of: Int32(animationAt).littleEndian) { Data($0) })
        if let animation {
            b.cstr("MDLA0006")
            b.int(0); b.int(1)
            b.int(animation.id); b.int(0)
            b.cstr("Animation 1"); b.cstr(animation.mode)
            b.float(animation.fps); b.int(animation.frames); b.int(0); b.int(Int32(animation.tracks.count))
            for track in animation.tracks {
                b.int(track.bone); b.int(Int32(track.keys.count * 36))
                for key in track.keys { b.floats(key) }
            }
            b.data.append(contentsOf: [UInt8](repeating: 0, count: 36))
        }
        _ = skeletonAt
        return b.data
    }

    /// 키프레임: 위치·회전·배율.
    private func key(_ x: Float, _ y: Float, rotation: Float = 0, sx: Float = 1, sy: Float = 1) -> [Float] {
        [x, y, 0, 0, 0, rotation, sx, sy, 1]
    }

    func testParsesVerticesBonesAndAnimation() throws {
        let data = makePuppet(
            vertices: [(SIMD2(10, 20), SIMD2(0.1, 0.2), 0, 1, 0, 0),
                       (SIMD2(30, 40), SIMD2(0.3, 0.4), 1, 0.75, 0, 0.25)],
            indices: [0, 1, 1],
            bones: [(-1, bindMatrix(x: 100, y: 50, rotation: 0.5), ""),
                    (0, bindMatrix(x: 10, y: 0, rotation: 0), #"{"a":null}"#)],
            animation: (7, "loop", 30, 2, [(0, [key(100, 50, rotation: 0.5), key(100, 50, rotation: 0.5), key(100, 50, rotation: 0.5)])]))
        let model = try PuppetModel.parse(data)
        XCTAssertEqual(model.materials, ["materials/a.json"])
        XCTAssertEqual(model.vertices.count, 2)
        XCTAssertEqual(model.vertices[1].position, SIMD2(30, 40))
        XCTAssertEqual(model.vertices[1].uv, SIMD2(0.3, 0.4))
        XCTAssertEqual(model.vertices[1].bones, SIMD4(1, 0, 0, 0))
        XCTAssertEqual(model.vertices[1].weights, SIMD4(0.75, 0.25, 0, 0))
        XCTAssertEqual(model.indices, [0, 1, 1])
        XCTAssertEqual(model.bones.count, 2)
        XCTAssertEqual(model.bones[0].parent, -1)
        XCTAssertEqual(model.bones[0].bind.position, SIMD2(100, 50))
        XCTAssertEqual(model.bones[0].bind.rotation, 0.5, accuracy: 1e-5)
        XCTAssertEqual(model.bones[1].parent, 0)
        XCTAssertEqual(model.animations.count, 1)
        XCTAssertEqual(model.animations[0].id, 7)
        XCTAssertEqual(model.animations[0].fps, 30)
        XCTAssertEqual(model.animations[0].frameCount, 2)
        XCTAssertEqual(model.animations[0].tracks[0]?.count, 3)
        XCTAssertTrue(model.animations[0].loops)
    }

    /// 첫 키프레임이 바인드 자세와 같으면(실물이 그렇다) 시각 0에는 정점이 그대로다.
    func testBindPoseLeavesVerticesInPlace() throws {
        let data = makePuppet(
            vertices: [(SIMD2(120, 80), SIMD2(0, 0), 0, 1, 0, 0)],
            indices: [0, 0, 0],
            bones: [(-1, bindMatrix(x: 100, y: 50, rotation: -1.04), "")],
            animation: (1, "loop", 30, 1, [(0, [key(100, 50, rotation: -1.04), key(100, 50, rotation: -1.04)])]))
        let model = try PuppetModel.parse(data)
        let positions = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 0))
        XCTAssertEqual(positions[0].x, 120, accuracy: 1e-3)
        XCTAssertEqual(positions[0].y, 80, accuracy: 1e-3)
    }

    /// 실물 눈 깜빡임: 뼈의 scale.y가 줄면 정점이 뼈 쪽으로 눌린다.
    func testScaleSquashesTowardBone() throws {
        let data = makePuppet(
            vertices: [(SIMD2(100, 150), SIMD2(0, 0), 0, 1, 0, 0)],
            indices: [0, 0, 0],
            bones: [(-1, bindMatrix(x: 100, y: 50, rotation: 0), "")],
            animation: (1, "loop", 30, 2, [(0, [key(100, 50), key(100, 50, sy: 0.5), key(100, 50)])]))
        let model = try PuppetModel.parse(data)
        // 1/30초 = 프레임 1: scale.y 0.5 → 뼈에서 100 위였던 정점이 50 위로.
        let positions = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 1.0 / 30))
        XCTAssertEqual(positions[0].x, 100, accuracy: 1e-3)
        XCTAssertEqual(positions[0].y, 100, accuracy: 1e-3)
        // 프레임 사이는 보간한다. 0.5프레임이면 scale 0.75.
        let mid = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 0.5 / 30))
        XCTAssertEqual(mid[0].y, 125, accuracy: 1e-3)
        // 되풀이: 2프레임 길이라 프레임 2는 다시 0이다.
        let wrapped = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 2.0 / 30))
        XCTAssertEqual(wrapped[0].y, 150, accuracy: 1e-3)
    }

    /// 부모가 돌면 자식 뼈에 붙은 정점도 같이 돈다.
    func testChildBoneFollowsParentRotation() throws {
        let data = makePuppet(
            vertices: [(SIMD2(20, 0), SIMD2(0, 0), 1, 1, 0, 0)],
            indices: [0, 0, 0],
            bones: [(-1, bindMatrix(x: 0, y: 0, rotation: 0), ""),
                    (0, bindMatrix(x: 10, y: 0, rotation: 0), "")],
            animation: (1, "loop", 30, 1, [(0, [key(0, 0, rotation: .pi / 2), key(0, 0, rotation: .pi / 2)])]))
        let model = try PuppetModel.parse(data)
        let positions = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 0))
        // 뿌리가 90° 돌면 (20, 0)은 (0, 20)으로 간다.
        XCTAssertEqual(positions[0].x, 0, accuracy: 1e-3)
        XCTAssertEqual(positions[0].y, 20, accuracy: 1e-3)
    }

    /// `blend`는 바인드 자세와 애니메이션 사이를 섞는다. 실물 값이 0.94다.
    func testBlendMixesTowardBindPose() throws {
        let data = makePuppet(
            vertices: [(SIMD2(0, 100), SIMD2(0, 0), 0, 1, 0, 0)],
            indices: [0, 0, 0],
            bones: [(-1, bindMatrix(x: 0, y: 0, rotation: 0), "")],
            animation: (1, "loop", 30, 1, [(0, [key(0, 0, sy: 0.5), key(0, 0, sy: 0.5)])]))
        let model = try PuppetModel.parse(data)
        let half = model.skinnedPositions(model.skinMatrices(animationID: 1, time: 0, blend: 0.5))
        XCTAssertEqual(half[0].y, 75, accuracy: 1e-3)
    }

    /// 모르는 애니메이션 id면 움직이지 않는다. 잘린 파일은 던진다.
    func testUnknownAnimationAndTruncation() throws {
        let data = makePuppet(
            vertices: [(SIMD2(5, 5), SIMD2(0, 0), 0, 1, 0, 0)], indices: [0, 0, 0],
            bones: [(-1, bindMatrix(x: 0, y: 0, rotation: 0), "")], animation: nil)
        let model = try PuppetModel.parse(data)
        XCTAssertEqual(model.animations, [])
        XCTAssertEqual(model.skinnedPositions(model.skinMatrices(animationID: 99, time: 1))[0], SIMD2(5, 5))
        XCTAssertThrowsError(try PuppetModel.parse(data.prefix(60)))
    }

    /// 실물 눈 깜빡임 메시. 뼈 둘, 300프레임 되풀이, 첫 프레임은 바인드와 같다.
    func testRealBlinkPuppetParses() throws {
        guard let root = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent("3793322447/scene.pkg")
        guard let raw = try? Data(contentsOf: url) else { throw XCTSkip("3793322447 없음") }
        let reader = try PkgReader(data: raw)
        let model = try PuppetModel.parse(try reader.data(for: "models/眼睛_puppet.mdl"))
        XCTAssertEqual(model.vertices.count, 218)
        XCTAssertEqual(model.indices.count, 1071)
        XCTAssertEqual(model.bones.count, 2)
        XCTAssertEqual(model.animations.count, 1)
        XCTAssertEqual(model.animations[0].id, 94)
        XCTAssertEqual(model.animations[0].frameCount, 300)
        XCTAssertEqual(model.animations[0].tracks.count, 2)
        // 시각 0 = 바인드 자세 → 정점이 제자리.
        let rest = model.skinnedPositions(model.skinMatrices(animationID: 94, time: 0))
        for (a, b) in zip(rest, model.vertices.map(\.position)) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.05)
            XCTAssertEqual(a.y, b.y, accuracy: 0.05)
        }
        // 깜빡임 도중에는 어떤 정점이 움직인다.
        let mid = model.skinnedPositions(model.skinMatrices(animationID: 94, time: 2.0 / 30))
        XCTAssertTrue(zip(mid, rest).contains { simd_distance($0, $1) > 0.5 })
        // 문서도 이 레이어에 퍼펫을 붙인다.
        let doc = try SceneDocument.load(from: reader)
        let eye = doc.layers.first { $0.name == "眼睛" }
        XCTAssertEqual(eye?.puppet?.path, "models/眼睛_puppet.mdl")
        XCTAssertEqual(eye?.puppet?.animations.first?.id, 94)
    }
}
