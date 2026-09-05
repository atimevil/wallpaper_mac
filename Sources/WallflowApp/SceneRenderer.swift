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
    /// 이 씬이 재생 중인 비디오 텍스처들. 렌더러가 소유한다.
    private var videos: [VideoTexture] = []

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    /// Wallpaper Engine의 표준 에셋. 사용자가 윈도우 설치 폴더에서 반입한다.
    /// 없으면 nil이고, 그 경우 표준 모델을 참조하는 레이어만 unsupported가 된다.
    static func defaultAssetsStore() -> AssetsStore? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Assets")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return AssetsStore(root: url)
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
        let assets = Self.defaultAssetsStore()
        let document = try SceneDocument.load(from: reader, assets: assets)

        let compositor = try MetalCompositor(device: device)
        compositor.setProjection(width: document.orthoWidth, height: document.orthoHeight)
        if document.clearEnabled {
            compositor.setClearColor(MTLClearColor(
                red: document.clearColor.x, green: document.clearColor.y,
                blue: document.clearColor.z, alpha: 1
            ))
        }

        let resolver = ReferenceResolver(pkg: reader, assets: assets)

        var videos: [VideoTexture] = []
        var drawable: [(QuadInstance, LayerSource)] = []

        for layer in document.layers where layer.visible {
            let quad = QuadInstance(
                origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                size: SIMD2(Float(layer.size.x), Float(layer.size.y)))

            switch layer.content {
            case .solidColor(let c):
                drawable.append((quad, .solid(SIMD4(Float(c.x), Float(c.y), Float(c.z), 1))))

            case .image(let path), .video(let path):
                guard let raw = resolver.data(for: path) else {
                    skipped.append("\(layer.name): 텍스처를 찾을 수 없다: \(path)")
                    continue
                }
                do {
                    let decoded = try TexDecoder.decode(raw)
                    if case .video(let mp4) = decoded {
                        let video = try VideoTexture(mp4: mp4, device: device)
                        video.play()
                        videos.append(video)
                        drawable.append((quad, .dynamic { [weak video] in video?.currentTexture() }))
                    } else {
                        let texture = try compositor.makeTexture(from: decoded)
                        drawable.append((quad, .fixed(texture)))
                    }
                } catch {
                    skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
                }

            case .unsupported(let reason):
                skipped.append("\(layer.name): \(reason)")
            }
        }
        self.videos = videos

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

        if !videos.isEmpty {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            // 전력 정책이 30fps를 지시한다. 60fps 소스라도 그 이상 그리지 않는다.
            view.preferredFramesPerSecond = PowerPolicy.normalFPS
        }

        view.needsDisplay = true
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            // 뷰를 숨기지 않는다. 마지막 프레임이 남아야 검은 화면이 되지 않는다.
            // 정적 씬은 애초에 그릴 것이 없어 이 분기가 아무 일도 하지 않는다.
            for video in videos { video.pause() }
            view?.isPaused = true
        case .playing(let fps):
            view?.isHidden = false
            for video in videos { video.play() }
            if !videos.isEmpty {
                view?.isPaused = false
                view?.preferredFramesPerSecond = fps
            }
            view?.needsDisplay = true
        }
    }

    func stop() {
        for video in videos { video.stop() }
        videos.removeAll()
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
