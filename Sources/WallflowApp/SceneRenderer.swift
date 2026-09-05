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

        var drawable: [(QuadInstance, LayerSource)] = []
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
                    .fixed(texture)
                ))
            } catch {
                skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
            }
        }

        // 건너뛴 이유는 drawable이 비어 폴백하는 경우에 사용자가 가장 필요로 한다.
        // isEmpty 가드보다 먼저 써야 그 경로에서도 진단이 버려지지 않는다.
        if !skipped.isEmpty {
            FileHandle.standardError.write(Data(
                "씬 \(item.title)에서 건너뛴 레이어 \(skipped.count)개:\n  "
                    .appending(skipped.joined(separator: "\n  "))
                    .appending("\n").utf8
            ))
        }

        guard !drawable.isEmpty else {
            // Metal 자체가 없는 경우(unsupportedType)와는 원인이 다르다 — 여기 도달했다는
            // 것 자체가 device가 있었다는 뜻이다. DisplayManager.attach는 어떤 오류든
            // 잡아 preview로 폴백하므로(WallflowApp/DisplayManager.swift 참고) 동작은
            // 바뀌지 않지만, 로그와 향후 분기를 위해 원인을 구분해 던진다.
            throw RendererError.noDrawableLayers
        }

        compositor.setLayers(drawable)
        self.compositor = compositor
        view.needsDisplay = true
    }

    func apply(_ directive: PlaybackDirective) {
        // M2의 씬은 완전히 정적이고 MTKView는 이미 isPaused = true다.
        // .paused에서 view를 숨기면 WallpaperWindow의 검은 배경이 드러나 사용자가
        // 자리를 비운 15분 동안 검은 화면을 보게 된다(PowerPolicy가 900초 후 이 상태로
        // 전환한다). 화면은 켜져 있고 바탕화면은 여전히 보여야 하므로, 정적 씬에서는
        // 숨길 이유가 없다 — VideoRenderer.apply가 일시정지만 하고 마지막 프레임을
        // 남겨두는 것과 같은 이유다. 이 no-op을 "복원"하지 말 것.
        switch directive {
        case .paused: break
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
