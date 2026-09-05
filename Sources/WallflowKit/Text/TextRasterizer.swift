import CoreGraphics
import CoreText
import Foundation

public enum TextRasterError: Error, Equatable {
    /// 글자가 없다. 0x0 텍스처는 Metal이 거부하므로 아예 만들지 않는다.
    case empty
    /// 폰트 바이트에서 폰트를 만들지 못했다.
    case badFont
    /// 그릴 넓이가 상한을 넘거나 0이다.
    case badSize(width: Int, height: Int)
    case contextCreationFailed
}

/// 글자를 비트맵으로 굽는다.
///
/// 폰트는 **시스템에 설치하지 않는다.** `CTFontManagerRegisterFontsForURL`은 사용자
/// 폰트 목록을 바꾸고 앱이 죽으면 남는다. 창작마당에서 받은 폰트를 사용자 시스템에
/// 심는 것은 배경화면 앱이 할 일이 아니다. 바이트에서 바로 descriptor를 만들어 쓴다.
public enum TextRasterizer {
    /// 한 변의 상한. 스크립트가 만든 글자가 길어질 수 있고, 폭은 글자 수에 비례한다.
    /// 텍스처 한 장의 상한(16384)과 같은 이유의 방어다.
    public static let maxDimension = 8192

    /// 글자를 RGBA 비트맵으로 굽는다.
    ///
    /// - Parameters:
    ///   - text: 그릴 글자.
    ///   - fontData: 폰트 파일 바이트. nil이면 시스템 폰트를 쓴다.
    ///   - pointSize: 글자 크기.
    ///   - color: 0~1 RGB.
    public static func rasterize(
        text: String, fontData: Data?, pointSize: Double, color: Vec3
    ) throws -> CGImage {
        guard !text.isEmpty, !text.allSatisfy(\.isWhitespace) else { throw TextRasterError.empty }
        guard pointSize.isFinite, pointSize > 0 else {
            throw TextRasterError.badSize(width: 0, height: 0)
        }

        let font = makeFont(data: fontData, pointSize: pointSize)
        // AppKit의 .font/.foregroundColor를 쓰지 않는다. 이 계층은 AppKit을 import하지
        // 않으므로 CoreText의 문자열 상수를 그대로 쓴다.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: clamp(color.x), green: clamp(color.y), blue: clamp(color.z), alpha: 1),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        // 타이포그래피 경계로 재면 글리프가 잘린다(이탤릭·장식 폰트에서 자주 그렇다).
        // 잉크 경계를 함께 봐서 넉넉히 잡는다.
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let typographicWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let inkBounds = CTLineGetImageBounds(line, nil)

        let padding = ceil(pointSize * 0.1)
        let width = Int(ceil(max(typographicWidth, inkBounds.maxX)) + padding * 2)
        let height = Int(ceil(ascent + descent + leading) + padding * 2)
        guard width > 0, height > 0,
              width <= maxDimension, height <= maxDimension else {
            throw TextRasterError.badSize(width: width, height: height)
        }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TextRasterError.contextCreationFailed }

        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        // CoreGraphics의 원점은 좌하단이다. baseline을 descent만큼 띄운다.
        context.textPosition = CGPoint(x: padding, y: descent + padding)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw TextRasterError.contextCreationFailed
        }
        return image
    }

    /// 폰트 바이트에서 폰트를 만든다. 실패하면 시스템 폰트로 대체한다 —
    /// 글자가 아예 안 나오는 것보다 다른 폰트로라도 나오는 게 낫다.
    /// 실물 씬 하나가 `systemfont_arial`처럼 파일이 아닌 이름을 쓰기도 한다.
    static func makeFont(data: Data?, pointSize: Double) -> CTFont {
        if let data, let provider = CGDataProvider(data: data as CFData),
           let cgFont = CGFont(provider) {
            return CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
        }
        return CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    }

    private static func clamp(_ v: Double) -> CGFloat {
        guard v.isFinite else { return 0 }
        return CGFloat(min(max(v, 0), 1))
    }
}
