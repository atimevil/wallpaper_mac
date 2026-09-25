import Foundation

/// 직교 씬의 캔버스를 화면(드로어블)에 맞추는 순수 수학.
///
/// WE 문서(성능/해상도)는 이렇게 적어 뒀다: "Wallpaper Engine will cut off the sides
/// of your wallpaper once you apply it to your desktop to make it fit to your screen."
/// 그래서 채우기(cover)가 기본이다 — 캔버스를 늘이지 않고 화면 비율에 맞게 옆이나
/// 위아래를 자른다. 다만 자르면 중요한 내용을 잃는 배경화면이 있어(왼쪽 끝의 날짜,
/// 세로형 캔버스) 배경화면마다 전체 보기·늘이기로 바꿀 수 있게 한다.
public enum CanvasFit {
    public enum Mode: String, Sendable, CaseIterable {
        /// 화면을 항상 꽉 채운다. 캔버스 비율이 화면과 다르면 옆이나 위아래가 잘린다.
        case cover
        /// 캔버스 전체가 항상 보인다. 화면 비율이 다르면 남는 자리는 씬의 clearcolor다.
        case contain
        /// 축마다 따로 늘여 캔버스를 화면에 정확히 맞춘다(자르지도 남기지도 않는다).
        /// 이 파일이 생기기 전까지의 동작과 같다.
        case stretch

        public static let `default`: Mode = .cover
    }

    /// 화면에 실제로 보이는 캔버스 사각형. 캔버스 중심에 맞춰 가운데 정렬된다.
    ///
    /// 셰이더는 `NDC = (world − origin) / size × 2 − 1`로 이 사각형을 쓴다(y 뒤집기는
    /// 각자의 규칙을 그대로 지킨다 — 가운데 정렬이라 원점의 오프셋은 y가 위로
    /// 증가하든 아래로 증가하든 같다).
    public struct Rect: Equatable, Sendable {
        public var origin: SIMD2<Double>
        public var size: SIMD2<Double>

        public init(origin: SIMD2<Double>, size: SIMD2<Double>) {
            self.origin = origin
            self.size = size
        }

        /// 화면 비율(0~1, 두 축 다 낮은 쪽이 0)을 캔버스 좌표로 옮긴다.
        /// `screenFraction(of:)`의 역이다 — 커서를 씬 좌표로 되돌릴 때 쓴다.
        public func canvasPoint(atScreenFraction fraction: SIMD2<Double>) -> SIMD2<Double> {
            origin + fraction * size
        }

        /// 캔버스 좌표를 화면 비율로 옮긴다. 셰이더의 NDC 매핑과 같은 식이다.
        public func screenFraction(of canvasPoint: SIMD2<Double>) -> SIMD2<Double> {
            (canvasPoint - origin) / size
        }
    }

    /// - Parameters:
    ///   - canvas: 씬의 직교 캔버스 크기(디자인 단위, `orthogonalprojection`).
    ///   - screen: 실제로 그릴 화면(드로어블)의 크기. 캔버스와 같은 축 단위이기만
    ///     하면 포인트든 픽셀이든 상관없다 — 결과는 가로세로 각각의 비율에만
    ///     좌우되고, 두 축을 같은 배율로 재도 그 비율은 그대로다.
    ///   - zoom: `general.zoom`. 저자가 편집기에서 정해 둔 확대율로, 배율에 곱한다
    ///     (1.08이면 8% 더 확대 = 보이는 사각형이 그만큼 작아진다). 0 이하이거나
    ///     유한하지 않으면(NaN·무한대·없음) 1로 본다.
    public static func visibleRect(
        canvas: SIMD2<Double>, screen: SIMD2<Double>, mode: Mode, zoom: Double
    ) -> Rect {
        guard canvas.x > 0, canvas.y > 0, screen.x > 0, screen.y > 0 else {
            return Rect(origin: .zero, size: canvas)
        }
        let safeZoom = zoom.isFinite && zoom > 0 ? zoom : 1
        let widthRatio = screen.x / canvas.x
        let heightRatio = screen.y / canvas.y
        let scale: SIMD2<Double>
        switch mode {
        case .cover:
            let s = Swift.max(widthRatio, heightRatio) * safeZoom
            scale = SIMD2(s, s)
        case .contain:
            let s = Swift.min(widthRatio, heightRatio) * safeZoom
            scale = SIMD2(s, s)
        case .stretch:
            scale = SIMD2(widthRatio, heightRatio) * safeZoom
        }
        let size = screen / scale
        let origin = (canvas - size) / 2
        return Rect(origin: origin, size: size)
    }

    /// `stored`(배경화면 id → `Mode.rawValue`)에서 이 배경화면의 방식을 찾는다.
    /// 저장된 적이 없거나 모르는 값이면 기본값(채우기)이다.
    public static func mode(for wallpaperID: String, in stored: [String: String]) -> Mode {
        stored[wallpaperID].flatMap(Mode.init(rawValue:)) ?? .default
    }

    /// `stored`에 이 배경화면의 방식을 저장한 새 사전을 돌려준다. 다른 배경화면의
    /// 값은 그대로 둔다.
    public static func settingMode(
        _ mode: Mode, for wallpaperID: String, in stored: [String: String]
    ) -> [String: String] {
        var updated = stored
        updated[wallpaperID] = mode.rawValue
        return updated
    }
}
