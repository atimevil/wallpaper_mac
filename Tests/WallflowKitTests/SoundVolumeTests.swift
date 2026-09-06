import XCTest

/// 소리 크기 설정. 씬이 정한 볼륨에 **곱한다**.
///
/// 덮어쓰면 씬 안의 균형이 깨진다 — 작게 깔아 둔 배경음이 대사와 같은 크기로 튄다.
/// 계산 자체는 `WallflowApp`에 있어 여기서는 규칙만 고정한다.
final class SoundVolumeTests: XCTestCase {
    /// 앱의 `SceneRenderer.soundVolume`과 같은 규칙.
    private func resolve(_ stored: Any?) -> Double {
        guard let value = stored as? Double, value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    /// 저장된 값이 없으면 100%다. 0으로 시작하면 사용자가 소리를 켜도 안 들린다.
    func testDefaultIsFullVolume() {
        XCTAssertEqual(resolve(nil), 1)
    }

    /// 설정은 손으로 고칠 수 있다. 범위를 벗어나면 죈다 —
    /// 1을 넘는 값을 AVAudioPlayer에 주면 소리가 깨진다.
    func testOutOfRangeIsClamped() {
        XCTAssertEqual(resolve(3.0), 1)
        XCTAssertEqual(resolve(-1.0), 0)
    }

    func testNonFiniteFallsBackToFull() {
        XCTAssertEqual(resolve(Double.nan), 1)
        XCTAssertEqual(resolve("절반"), 1)
    }

    /// 씬 볼륨에 곱한다. 0.5짜리 씬을 50%로 들으면 0.25다.
    func testUserVolumeMultipliesSceneVolume() {
        let scene: Float = 0.5
        XCTAssertEqual(scene * Float(resolve(0.5)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(scene * Float(resolve(nil)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(scene * Float(resolve(0.0)), 0, accuracy: 0.0001)
    }
}
