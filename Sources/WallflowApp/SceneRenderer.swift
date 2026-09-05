import AppKit
import Metal
import QuartzCore
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
    /// 파티클 레이어마다 시뮬레이션과 렌더러 한 쌍. 매 프레임 전진시킨다.
    private var particles: [(system: ParticleSystem, renderer: ParticleRenderer,
                             textureRatio: Float)] = []
    /// 직전 프레임 시각. 첫 프레임에는 없다.
    private var lastFrameTime: CFTimeInterval?

    /// 씬 하나가 동시에 열 수 있는 비디오 레이어 수. 보유한 실물 씬 넷은 각각
    /// 최대 1개뿐이라 4는 정상 콘텐츠에 넉넉하다. 상한이 없으면 악의적인
    /// .pkg가 레이어 수십 개마다 AVPlayer+텍스처 캐시를 띄워 메모리와 디코더를
    /// 소진할 수 있다 — DisplayManager는 디스플레이마다 별도 SceneRenderer를
    /// 만들어 아무것도 공유하지 않으므로 모니터 수만큼 곱해진다.
    private static let maxConcurrentVideoLayers = 4
    /// 비디오 페이로드 하나의 상한. 실물에서 가장 큰 것이 226MB였다. 256MB는
    /// 그보다 위이면서도 디스크 쓰기 한 번의 크기를 계속 작게 묶어 둔다.
    private static let maxVideoPayloadBytes = 256 * 1024 * 1024

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    /// 파티클 텍스처가 스프라이트 시트면 그 배치를 읽는다.
    /// `rosepetals.tex`가 512x128에 102x128 프레임 5장이다. 시트인 줄 모르고
    /// uv 0..1로 샘플링하면 꽃잎 하나가 다섯 장을 뭉개 그린다.
    private static func spriteSheet(of raw: Data) -> ParticleSpriteSheet? {
        guard let header = try? TexHeader.parse(raw), let sheet = header.spriteSheet,
              sheet.frameCount > 1,
              let gridWidth = sheet.gridWidth, let gridHeight = sheet.gridHeight,
              gridWidth > 0, gridHeight > 0,
              header.textureWidth > 0, header.textureHeight > 0
        else { return nil }
        // 한 줄에 몇 칸이 들어가는지. 폭이 딱 나누어떨어지지 않는 시트가 있어
        // 내림으로 센다(rosepetals는 5칸 510px에 2px가 남는다).
        let perRow = max(1, header.textureWidth / gridWidth)
        return ParticleSpriteSheet(
            frameCount: sheet.frameCount,
            framesPerRow: perRow,
            frameScale: SIMD2(Float(gridWidth) / Float(header.textureWidth),
                              Float(gridHeight) / Float(header.textureHeight)),
            frameRatio: Float(gridHeight) / Float(gridWidth))
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
        // mmap을 쓰지 않는다. 이 파일은 SteamCmdClient가 관리하는 워크숍 콘텐츠라
        // 로딩 도중 업데이트가 덮어써 잘리면 매핑이 SIGBUS로 죽는다 — Swift 오류가
        // 아니라 프로세스 종료라 잡을 수 없다. AssetsStore.data(for:)의 판단과 같다.
        let raw = try Data(
            contentsOf: item.directory.appendingPathComponent("scene.pkg")
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
        var particles: [(system: ParticleSystem, renderer: ParticleRenderer,
                         textureRatio: Float)] = []
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
                        guard mp4.count <= Self.maxVideoPayloadBytes else {
                            skipped.append(
                                "\(layer.name): 비디오 페이로드가 상한(\(Self.maxVideoPayloadBytes) bytes)을 "
                                    + "넘는다 (\(mp4.count) bytes)")
                            continue
                        }
                        guard videos.count < Self.maxConcurrentVideoLayers else {
                            skipped.append(
                                "\(layer.name): 씬당 비디오 레이어 상한(\(Self.maxConcurrentVideoLayers)개)을 "
                                    + "넘어 건너뛴다")
                            continue
                        }
                        let video = try VideoTexture(mp4: mp4, device: device)
                        // status는 init 직후 대개 .unknown이라 이 검사는 이미 동기적으로
                        // 실패가 확정된 드문 경우만 잡는다. 나머지는 VideoTexture.currentTexture()가
                        // 매 프레임 다시 확인해 stderr에 알린다 (VideoTexture 참고).
                        guard !video.hasFailed else {
                            skipped.append("\(layer.name): 비디오를 재생할 수 없다")
                            continue
                        }
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

            case .particle(let preset, let texturePath, let blend):
                guard let raw = resolver.data(for: texturePath) else {
                    skipped.append("\(layer.name): 파티클 텍스처를 찾을 수 없다: \(texturePath)")
                    continue
                }
                do {
                    let decoded = try TexDecoder.decode(raw)
                    guard case .video = decoded else {
                        let texture = try compositor.makeTexture(from: decoded)
                        // 빌보드가 찌그러지지 않게 세로를 보정한다.
                        let ratio = texture.width > 0
                            ? Float(texture.height) / Float(texture.width) : 1
                        let renderer = try compositor.makeParticleRenderer(
                            maxCount: preset.maxCount, blend: blend, texture: texture,
                            layerOrigin: SIMD3(Float(layer.origin.x), Float(layer.origin.y),
                                               Float(layer.origin.z)),
                            sheet: Self.spriteSheet(of: raw))
                        // 시드를 레이어 id로 나눠 레이어마다 다른 수열을 쓴다.
                        // 같은 시드를 공유하면 눈과 벚꽃이 똑같이 움직인다.
                        let system = ParticleSystem(
                            preset: preset, random: SeededRandom(seed: UInt64(bitPattern: Int64(layer.id))))
                        if !system.unimplementedOperators.isEmpty {
                            skipped.append(
                                "\(layer.name): 아직 처리하지 않는 연산자 "
                                    + system.unimplementedOperators.joined(separator: ", "))
                        }
                        particles.append((system, renderer, ratio))
                        drawable.append((quad, .particles(renderer)))
                        break
                    }
                    skipped.append("\(layer.name): 파티클 텍스처가 비디오다: \(texturePath)")
                } catch {
                    skipped.append("\(layer.name): 파티클 텍스처 로드 실패 \(error)")
                }

            case .unsupported(let reason):
                skipped.append("\(layer.name): \(reason)")
            }
        }
        self.videos = videos
        self.particles = particles

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

        // 비디오와 파티클은 둘 다 매 프레임 갱신이 필요하다.
        if !videos.isEmpty || !particles.isEmpty {
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
            // 다시 재생할 때 멈춰 있던 시간이 통째로 적분되지 않게 한다.
            // 시뮬레이션이 스스로 죄지만, 여기서 끊어야 파티클이 튀지 않는다.
            lastFrameTime = nil
        case .playing(let fps):
            view?.isHidden = false
            // VideoRenderer.apply와 맞춘다: 이미 재생 중이면 다시 부르지 않는다.
            for video in videos where !video.isPlaying { video.play() }
            if !videos.isEmpty || !particles.isEmpty {
                view?.isPaused = false
                view?.preferredFramesPerSecond = fps
            }
            view?.needsDisplay = true
        }
    }

    func stop() {
        for video in videos { video.stop() }
        videos.removeAll()
        particles.removeAll()
        lastFrameTime = nil
        compositor = nil
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        if !particles.isEmpty {
            let now = CACurrentMediaTime()
            // 첫 프레임에는 직전 시각이 없다. 0을 넘기면 시뮬레이션이 그냥 넘어간다.
            let dt = lastFrameTime.map { now - $0 } ?? 0
            lastFrameTime = now
            for entry in particles {
                entry.system.update(deltaTime: dt)
                entry.renderer.update(from: entry.system, textureRatio: entry.textureRatio)
            }
        }
        compositor?.draw(in: view)
    }
}
