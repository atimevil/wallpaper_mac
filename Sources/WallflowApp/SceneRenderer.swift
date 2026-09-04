import AppKit
import Metal
import MetalKit
import WallflowKit

/// scene.pkg를 열어 이미지 레이어를 Metal로 그린다.
///
/// M2가 그리는 것은 이미지 레이어뿐이다. 파티클·텍스트·이펙트·비디오 텍스처는
/// SceneDocument가 unsupported로 표시하며, 여기서는 조용히 건너뛴다.
/// 그릴 수 있는 레이어가 하나도 없으면 start()가 던져 상위가 preview로 폴백한다.
@MainActor
final class SceneRenderer: NSObject, WallpaperRenderer {
    private let item: WallpaperItem
    private var view: MTKView?
    private var compositor: MetalCompositor?
    private var skipped: [String] = []

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    func makeView() -> NSView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // 컴포지터의 파이프라인이 bgra8Unorm으로 고정돼 있다. 기본값에 기대지 않고
        // 명시한다. 어긋나면 빌드는 통과하고 화면만 검게 나온다.
        view.colorPixelFormat = .bgra8Unorm
        view.autoresizingMask = [.width, .height]
        view.isPaused = true                 // 정적 씬이라 필요할 때만 그린다
        view.enableSetNeedsDisplay = true
        view.delegate = self
        self.view = view
        return view
    }

    func start() throws {
        guard let view, let device = view.device else {
            throw RendererError.unsupportedType(.scene)
        }

        // project.json의 file은 scene.json을 가리키지만 실제 데이터는 scene.pkg에 있다.
        let raw = try Data(
            contentsOf: item.directory.appendingPathComponent("scene.pkg"),
            options: .mappedIfSafe
        )
        let reader = try PkgReader(data: raw)
        let document = try SceneDocument.load(from: reader)

        let compositor = try MetalCompositor(device: device)
        compositor.setProjection(width: document.orthoWidth, height: document.orthoHeight)
        if document.clearEnabled {
            compositor.setClearColor(MTLClearColor(
                red: document.clearColor.x, green: document.clearColor.y,
                blue: document.clearColor.z, alpha: 1
            ))
        }

        var drawable: [(QuadInstance, MTLTexture)] = []
        for layer in document.layers where layer.visible {
            guard case .image(let path) = layer.content else {
                if case .unsupported(let reason) = layer.content {
                    skipped.append("\(layer.name): \(reason)")
                }
                continue
            }
            do {
                let texture = try compositor.makeTexture(
                    from: try TexDecoder.decode(try reader.data(for: path))
                )
                drawable.append((
                    QuadInstance(
                        origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                        size: SIMD2(Float(layer.size.x), Float(layer.size.y))
                    ),
                    texture
                ))
            } catch {
                skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
            }
        }

        guard !drawable.isEmpty else {
            throw RendererError.unsupportedType(.scene)
        }

        compositor.setLayers(drawable)
        self.compositor = compositor

        if !skipped.isEmpty {
            FileHandle.standardError.write(Data(
                "씬 \(item.title)에서 건너뛴 레이어 \(skipped.count)개:\n  "
                    .appending(skipped.joined(separator: "\n  "))
                    .appending("\n").utf8
            ))
        }
        view.needsDisplay = true
    }

    func apply(_ directive: PlaybackDirective) {
        // M2의 씬은 정적이라 프레임레이트가 의미 없다. 정지 시 그리기만 멈춘다.
        switch directive {
        case .paused: view?.isHidden = true
        case .playing:
            view?.isHidden = false
            view?.needsDisplay = true
        }
    }

    func stop() {
        compositor = nil
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        compositor?.draw(in: view)
    }
}
