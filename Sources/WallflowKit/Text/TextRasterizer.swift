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

/// 구운 글자의 BGRA8 프리멀티플라이드 픽셀 버퍼.
///
/// `CGImage`는 Swift 6에서 `Sendable`이 아니다 — 내부가 언제 바뀔지 컴파일러가
/// 보장할 수 없는 참조 타입이라서다. 굽기를 백그라운드 큐로 옮기고 결과만
/// 메인 액터로 넘기려면 값 타입이면서 Sendable인 결과가 필요하다.
///
/// 채널 순서는 B,G,R,A다 — `MTLPixelFormat.bgra8Unorm`과 같은 배치라, 이 값을
/// 받는 쪽(App)이 채널을 다시 섞을 필요 없이 `replace(region:...)`로 바로
/// Metal 텍스처에 올릴 수 있다.
public struct TextPixelBuffer: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
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

    /// `CGImage`를 돌려주는 경로의 바이트 배치. premultipliedLast + 기본(빅엔디언)
    /// 순서라 메모리상 R,G,B,A다. CGImage가 필요한 나머지 호출부를 위해 그대로 둔다.
    private static let rgbaBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// 픽셀 버퍼를 돌려주는 경로의 바이트 배치. premultipliedFirst + 리틀엔디언 =
    /// 메모리상 B,G,R,A(`bgra8Unorm`과 같다). `MTKTextureLoader` 없이
    /// `replace(region:...)`로 바로 올리려고 처음부터 이 배치로 굽는다.
    private static let bgraBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    /// 글자를 RGBA 비트맵으로 굽는다.
    ///
    /// - Parameters:
    ///   - text: 그릴 글자.
    ///   - fontData: 폰트 파일 바이트. nil이면 시스템 폰트를 쓴다.
    ///   - pointSize: 글자 크기.
    ///   - color: 0~1 RGB.
    /// 여러 줄로 접어 굽는다. `wrapWidth`가 0이면 한 줄로 둔다.
    ///
    /// 씬이 `limitwidth`로 폭을 정해 두는데 그걸 무시하면 긴 곡 제목이 한 줄로
    /// 늘어져 화면 밖으로 흐른다. `maxRows`를 넘기면 잘라내고, 씬이 그러라고
    /// 하면 말줄임표를 붙인다.
    public static func rasterize(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        wrapWidth: Double, maxRows: Int, usesEllipsis: Bool,
        shadow: TextShadow? = nil, shadowScale: Double = 1,
        extraPadding: Vec2 = Vec2(x: 0, y: 0),
        horizontalAlign: TextAlignment = .left, blockAlign: Bool = false
    ) throws -> CGImage {
        let (context, _, _) = try rasterizeToContext(
            text: text, fontData: fontData, pointSize: pointSize, color: color,
            wrapWidth: wrapWidth, maxRows: maxRows, usesEllipsis: usesEllipsis,
            shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
            horizontalAlign: horizontalAlign, blockAlign: blockAlign,
            bitmapInfo: rgbaBitmapInfo)
        guard let image = context.makeImage() else {
            throw TextRasterError.contextCreationFailed
        }
        return image
    }

    /// 위 `rasterize`와 같은 값을 같은 레이아웃 규칙으로 굽지만, 결과가
    /// `CGImage`가 아니라 Sendable 픽셀 버퍼다.
    ///
    /// 백그라운드 큐에서 굽고 결과만 메인 액터로 넘기는 경로(글자가 자주
    /// 바뀌는 스크립트 구동 레이어)에서 쓴다 — CGImage는 그 경계를 못 넘는다.
    public static func rasterizePixels(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        wrapWidth: Double, maxRows: Int, usesEllipsis: Bool,
        shadow: TextShadow? = nil, shadowScale: Double = 1,
        extraPadding: Vec2 = Vec2(x: 0, y: 0),
        horizontalAlign: TextAlignment = .left, blockAlign: Bool = false
    ) throws -> TextPixelBuffer {
        let (context, width, height) = try rasterizeToContext(
            text: text, fontData: fontData, pointSize: pointSize, color: color,
            wrapWidth: wrapWidth, maxRows: maxRows, usesEllipsis: usesEllipsis,
            shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
            horizontalAlign: horizontalAlign, blockAlign: blockAlign,
            bitmapInfo: bgraBitmapInfo)
        return try pixelBuffer(from: context, width: width, height: height)
    }

    /// 줄바꿈 여부를 갈라 단일 줄/문단 경로로 보낸다.
    ///
    /// `CGImage`·픽셀 버퍼 두 공개 API가 이 판단과 CoreText 레이아웃을 그대로
    /// 공유한다 — 다른 것은 마지막에 컨텍스트를 어떤 바이트 배치로 만드는지뿐이다.
    private static func rasterizeToContext(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        wrapWidth: Double, maxRows: Int, usesEllipsis: Bool,
        shadow: TextShadow?, shadowScale: Double, extraPadding: Vec2,
        horizontalAlign: TextAlignment, blockAlign: Bool, bitmapInfo: UInt32
    ) throws -> (context: CGContext, width: Int, height: Int) {
        // 줄바꿈이 있으면 폭 제한이 없어도 여러 줄이다. **실물 시계 위젯의
        // 날짜가 한 글자씩 줄바꿈으로 세로로 쌓는다** — `"0\n7\n\nS\nE\nP"` 꼴이다.
        // 줄바꿈을 무시하면 그게 한 줄로 이어져, 상자에 맞추느라 깨알같이 작아진다.
        let hasHardBreak = text.contains(where: \.isNewline)
        guard wrapWidth > 0, wrapWidth.isFinite else {
            if !hasHardBreak {
                return try rasterizeLineToContext(
                    text: text, fontData: fontData, pointSize: pointSize, color: color,
                    shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
                    bitmapInfo: bitmapInfo)
            }
            return try rasterizeParagraphsToContext(
                text: text, fontData: fontData, pointSize: pointSize, color: color,
                wrapWidth: 0, maxRows: maxRows, usesEllipsis: usesEllipsis,
                shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
                horizontalAlign: horizontalAlign, blockAlign: blockAlign, bitmapInfo: bitmapInfo)
        }
        return try rasterizeParagraphsToContext(
            text: text, fontData: fontData, pointSize: pointSize, color: color,
            wrapWidth: wrapWidth, maxRows: maxRows, usesEllipsis: usesEllipsis,
            shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
            horizontalAlign: horizontalAlign, blockAlign: blockAlign, bitmapInfo: bitmapInfo)
    }

    /// 줄바꿈으로 먼저 나누고, 각 문단을 폭에 맞춰 다시 접는다.
    ///
    /// 빈 줄도 한 줄만큼 자리를 차지해야 한다 — 실물 날짜가 묶음 사이를 빈 줄로
    /// 띄운다(`"0\n7\n\nS\nE\nP"`). 빈 줄을 버리면 글자가 위로 붙어 버린다.
    private static func rasterizeParagraphsToContext(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        wrapWidth: Double, maxRows: Int, usesEllipsis: Bool,
        shadow: TextShadow?, shadowScale: Double, extraPadding: Vec2,
        horizontalAlign: TextAlignment, blockAlign: Bool, bitmapInfo: UInt32
    ) throws -> (context: CGContext, width: Int, height: Int) {
        guard !text.isEmpty, !text.allSatisfy(\.isWhitespace) else { throw TextRasterError.empty }
        guard pointSize.isFinite, pointSize > 0 else {
            throw TextRasterError.badSize(width: 0, height: 0)
        }

        let font = makeFont(data: fontData, pointSize: pointSize)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: clamp(color.x), green: clamp(color.y), blue: clamp(color.z), alpha: 1),
        ]

        // 줄을 직접 나눈다. CTFramesetter는 높이를 미리 알아야 해서 두 번 재야 한다.
        var lines: [CTLine] = []
        let limit = maxRows > 0 ? maxRows : 64
        // 빈 줄인지 함께 들고 있는다. 그려도 아무것도 안 나오지만 자리는 차지한다.
        let paragraphs = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for paragraph in paragraphs where lines.count < limit {
            if paragraph.isEmpty {
                lines.append(CTLineCreateWithAttributedString(
                    NSAttributedString(string: " ", attributes: attributes)))
                continue
            }
            if wrapWidth <= 0 {
                lines.append(CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(paragraph), attributes: attributes)))
                continue
            }
            appendWrapped(paragraph, into: &lines, limit: limit,
                          wrapWidth: wrapWidth, usesEllipsis: usesEllipsis,
                          attributes: attributes)
        }
        guard !lines.isEmpty else { throw TextRasterError.empty }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(lines[0], &ascent, &descent, &leading)
        let lineHeight = ceil(ascent + descent + leading)
        let paddingX = ceil(pointSize * 0.1 + shadowPadding(shadow, scale: shadowScale))
            + CGFloat(extraPadding.x)
        let paddingY = ceil(pointSize * 0.1 + shadowPadding(shadow, scale: shadowScale))
            + CGFloat(extraPadding.y)
        let lineWidths = lines.map { max(CTLineGetTypographicBounds($0, nil, nil, nil),
                                         CTLineGetImageBounds($0, nil).maxX) }
        let widest = lineWidths.max() ?? 0
        let width = Int(ceil(widest) + paddingX * 2)
        let height = Int(lineHeight * CGFloat(lines.count) + paddingY * 2)
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else {
            throw TextRasterError.badSize(width: width, height: height)
        }
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { throw TextRasterError.contextCreationFailed }
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        applyShadow(shadow, in: context, scale: shadowScale)
        for (index, line) in lines.enumerated() {
            // CoreGraphics의 원점은 좌하단이라 첫 줄이 맨 위에 오도록 뒤에서 센다.
            let baseline = CGFloat(lines.count - index - 1) * lineHeight + descent + paddingY
            // `blockalign`이 꺼져 있으면(실물 115개 전부) 줄마다 자기 폭 기준으로
            // 정렬한다 — 가운데·오른쪽 정렬인 여러 줄 글자가 지그재그로 벌어지는
            // 게 아니라 각 줄이 제 폭 안에서 붙는다. 켜져 있으면(실물엔 없다)
            // 예전처럼 전체 블록을 가장 넓은 줄 기준 왼쪽에 통째로 붙인다 —
            // 바깥의 상자 정렬이 블록 전체를 한 덩어리로 옮긴다.
            let lineX: CGFloat
            if blockAlign {
                lineX = paddingX
            } else {
                let slack = CGFloat(widest) - lineWidths[index]
                switch horizontalAlign {
                case .left: lineX = paddingX
                case .center: lineX = paddingX + slack / 2
                case .right: lineX = paddingX + slack
                }
            }
            context.textPosition = CGPoint(x: lineX, y: baseline)
            CTLineDraw(line, context)
        }
        return (context, width, height)
    }

    /// 문단 하나를 폭에 맞춰 접어 줄 목록에 붙인다.
    private static func appendWrapped(
        _ paragraph: Substring, into lines: inout [CTLine], limit: Int,
        wrapWidth: Double, usesEllipsis: Bool,
        attributes: [NSAttributedString.Key: Any]
    ) {
        var remaining = paragraph
        while !remaining.isEmpty, lines.count < limit {
            let attributed = NSAttributedString(string: String(remaining), attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let count = CTTypesetterSuggestLineBreak(typesetter, 0, wrapWidth)
            guard count > 0 else { break }
            let isLast = lines.count == limit - 1 && count < remaining.count
            if isLast, usesEllipsis {
                // 마지막 줄이 잘리면 말줄임표를 붙인다. 자리를 만들려고 조금 줄인다.
                let head = String(remaining.prefix(max(1, count - 1))) + "…"
                lines.append(CTLineCreateWithAttributedString(
                    NSAttributedString(string: head, attributes: attributes)))
                return
            }
            let piece = String(remaining.prefix(count))
            lines.append(CTLineCreateWithAttributedString(
                NSAttributedString(string: piece, attributes: attributes)))
            remaining = remaining.dropFirst(count)
        }
    }

    public static func rasterize(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        shadow: TextShadow? = nil, shadowScale: Double = 1,
        extraPadding: Vec2 = Vec2(x: 0, y: 0)
    ) throws -> CGImage {
        let (context, _, _) = try rasterizeLineToContext(
            text: text, fontData: fontData, pointSize: pointSize, color: color,
            shadow: shadow, shadowScale: shadowScale, extraPadding: extraPadding,
            bitmapInfo: rgbaBitmapInfo)
        guard let image = context.makeImage() else {
            throw TextRasterError.contextCreationFailed
        }
        return image
    }

    /// 줄바꿈 없이 한 줄만 굽는다. 문단 경로보다 가벼워, 대다수(줄바꿈 없는)
    /// 글자가 여길 지난다.
    private static func rasterizeLineToContext(
        text: String, fontData: Data?, pointSize: Double, color: Vec3,
        shadow: TextShadow?, shadowScale: Double, extraPadding: Vec2, bitmapInfo: UInt32
    ) throws -> (context: CGContext, width: Int, height: Int) {
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

        let paddingX = ceil(pointSize * 0.1 + shadowPadding(shadow, scale: shadowScale))
            + CGFloat(extraPadding.x)
        let paddingY = ceil(pointSize * 0.1 + shadowPadding(shadow, scale: shadowScale))
            + CGFloat(extraPadding.y)
        let width = Int(ceil(max(typographicWidth, inkBounds.maxX)) + paddingX * 2)
        let height = Int(ceil(ascent + descent + leading) + paddingY * 2)
        guard width > 0, height > 0,
              width <= maxDimension, height <= maxDimension else {
            throw TextRasterError.badSize(width: width, height: height)
        }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { throw TextRasterError.contextCreationFailed }

        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        applyShadow(shadow, in: context, scale: shadowScale)
        // CoreGraphics의 원점은 좌하단이다. baseline을 descent만큼 띄운다.
        context.textPosition = CGPoint(x: paddingX, y: descent + paddingY)
        CTLineDraw(line, context)

        return (context, width, height)
    }

    /// 그려진 컨텍스트에서 픽셀을 그대로 복사해 Sendable 버퍼로 만든다.
    ///
    /// `CGContext.data`는 이 컨텍스트가 살아 있는 동안만 유효한 포인터다.
    /// `Data(bytes:count:)`로 즉시 복사해야 컨텍스트가 사라진 뒤에도 안전하고,
    /// 스레드(액터) 경계도 넘을 수 있다.
    private static func pixelBuffer(
        from context: CGContext, width: Int, height: Int
    ) throws -> TextPixelBuffer {
        guard let base = context.data else { throw TextRasterError.contextCreationFailed }
        let bytesPerRow = context.bytesPerRow
        let data = Data(bytes: base, count: bytesPerRow * height)
        return TextPixelBuffer(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// 구운 글자를 씬이 정한 상자에 비율 그대로 맞춘다.
    ///
    /// 오브젝트의 `size`는 글자 크기가 아니라 **상자**다. 실물에 411x5300짜리도 있어서
    /// 그대로 점 크기로 쓰면 글자가 화면 밖으로 밀려난다. 상자가 없거나(0) 이미지가
    /// 비었으면 원래 크기를 그대로 쓴다.
    public static func fit(
        imageWidth: Int, imageHeight: Int, boxWidth: Double, boxHeight: Double
    ) -> (width: Double, height: Double) {
        let w = Double(imageWidth), h = Double(imageHeight)
        guard w > 0, h > 0 else { return (0, 0) }
        guard boxWidth > 0, boxHeight > 0, boxWidth.isFinite, boxHeight.isFinite else {
            return (w, h)
        }
        let scale = Swift.min(boxWidth / w, boxHeight / h)
        guard scale.isFinite, scale > 0 else { return (w, h) }
        return (w * scale, h * scale)
    }

    /// 저장된 글자와 상자를 견줘 "구운 픽셀 → 씬 단위" 배율을 얻는다.
    ///
    /// 오브젝트의 `size`는 **편집기에 저장된 글자**의 크기다. 실행 중에 글자가
    /// 길어지면(`Date` → `07 SEP 2026`) 상자에 맞추는 순간 글자가 쪼그라든다 —
    /// 실물에서 시계·날짜가 자리표시자로 저장돼 있어 거의 모든 씬이 이 경우다.
    /// 배율은 저장된 글자에서 한 번 얻어 두고, 실행 중 글자에는 그 배율을 그대로
    /// 쓴다. 글자 크기가 고정되고 긴 글자는 상자를 넘어간다 — 실물이 그렇다.
    ///
    /// 저장된 글자를 못 구웠거나 상자가 없으면 nil이다. 그때는 상자에 맞추는
    /// 예전 방식으로 돌아간다.
    public static func unitsPerPixel(
        authoredWidth: Int, authoredHeight: Int, boxWidth: Double, boxHeight: Double
    ) -> Double? {
        let w = Double(authoredWidth), h = Double(authoredHeight)
        guard w > 0, h > 0, boxWidth > 0, boxHeight > 0,
              boxWidth.isFinite, boxHeight.isFinite else { return nil }
        // 가로세로 비가 살짝 달라도 글자가 상자를 넘지 않게 작은 쪽을 쓴다.
        let scale = Swift.min(boxWidth / w, boxHeight / h)
        guard scale.isFinite, scale > 0 else { return nil }
        return scale
    }

    /// 그림자를 켠다. 켠 뒤에 그린 것에만 붙는다.
    ///
    /// 그림자는 글자 바깥으로 번지므로 비트맵에 여백이 더 필요하다.
    /// 여백을 안 주면 오른쪽·아래가 잘려 그림자가 각지게 끊긴다.
    static func applyShadow(_ shadow: TextShadow?, in context: CGContext, scale: Double) {
        guard let shadow, shadow.opacity > 0 else { return }
        let color = CGColor(
            red: clamp(shadow.color.x), green: clamp(shadow.color.y),
            blue: clamp(shadow.color.z), alpha: CGFloat(shadow.opacity))
        // CoreGraphics의 y는 위가 양수라 씬의 아래 방향과 부호가 반대다.
        context.setShadow(
            offset: CGSize(width: shadow.offset.x * scale, height: -shadow.offset.y * scale),
            blur: CGFloat(max(shadow.blur, 0) * scale),
            color: color)
    }

    /// 그림자가 번지는 만큼의 여백.
    static func shadowPadding(_ shadow: TextShadow?, scale: Double) -> Double {
        guard let shadow, shadow.opacity > 0 else { return 0 }
        return (abs(shadow.offset.x).magnitude + abs(shadow.offset.y).magnitude
                + max(shadow.blur, 0) * 2) * scale
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
