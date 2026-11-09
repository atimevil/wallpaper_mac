import AppKit
// 사용: makeicon <원본> <x> <y> <변> <출력png>
// 원본의 정사각형 부분을 잘라 macOS 아이콘 틀(1024 캔버스, 824 몸체, 둥근 모서리, 옅은 그림자)에 넣는다.
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let crop = src.cropping(to: CGRect(x: Double(a[2])!, y: Double(a[3])!, width: Double(a[4])!, height: Double(a[4])!))!
let size = 1024, body: CGFloat = 824, inset = (CGFloat(size) - body) / 2
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: inset, y: inset + 10, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath(); ctx.restoreGState()
ctx.addPath(path); ctx.clip(); ctx.interpolationQuality = .high; ctx.draw(crop, in: rect)
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! out.write(to: URL(fileURLWithPath: a[5]))
