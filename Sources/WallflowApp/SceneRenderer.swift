import AVFoundation
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
    /// 그리기는 하는데 온전하지 않은 레이어. 건너뛴 것과 섞으면 사용자가
    /// "안 그려진 것"과 "덜 그려진 것"을 구별하지 못한다.
    private var degraded: [String] = []
    /// 이 씬이 재생 중인 비디오 텍스처들. 렌더러가 소유한다.
    private var videos: [VideoTexture] = []
    /// 파티클 레이어마다 시뮬레이션과 렌더러 한 쌍. 매 프레임 전진시킨다.
    private var particles: [(system: ParticleSystem, renderer: ParticleRenderer,
                             textureRatio: Float)] = []
    /// 직전 프레임 시각. 첫 프레임에는 없다.
    private var lastFrameTime: CFTimeInterval?
    /// 텍스트 레이어마다 스크립트와 구운 글자. 값이 바뀔 때만 다시 굽는다.
    private var texts: [TextState] = []
    /// 스크립트를 마지막으로 돌린 시각. 시계는 초 단위로 바뀌므로 1초에 한 번이면 된다.
    private var lastScriptTime: CFTimeInterval?
    /// 스크립트를 다시 돌리는 주기.
    private static let scriptInterval: CFTimeInterval = 1.0
    /// 이 씬의 소리들. 사용자가 켤 때만 실제로 난다.
    private var sounds: [AVAudioPlayer] = []
    /// 전력 정책이 재생을 멈췄는지.
    ///
    /// `MTKView.isPaused`로 판단하면 안 된다. 정적인 씬은 그릴 것이 없어 뷰가 늘
    /// 정지 상태인데, 소리는 그리기와 무관하게 나야 한다.
    private var playbackPaused = false
    /// 씬 소리를 낼지. 배경화면이 로그인할 때마다 소리를 내면 곤란하므로 기본은 끔이다.
    /// 메뉴에서 켜면 UserDefaults에 남는다.
    static var soundEnabled: Bool {
        UserDefaults.standard.bool(forKey: "wallflow.soundEnabled")
    }
    /// 컴포지터에 준 레이어 목록. 글자 크기가 바뀌면 다시 줘야 해서 들고 있는다.
    private var layerList: [(QuadInstance, LayerSource)] = []

    /// 텍스트 레이어 하나의 상태.
    ///
    /// 스크립트는 **렌더 스레드에서 돌리지 않는다.** 창작마당 코드라 무한 루프가
    /// 있을 수 있고 그것을 중단시킬 공개 API가 없다(ScriptEngine 참고). 레이어마다
    /// 직렬 큐 하나에 가둬 두면, 폭주해도 그 레이어의 글자만 마지막 값에서 멈추고
    /// 화면과 나머지 레이어는 계속 돈다.
    @MainActor
    private final class TextState {
        let text: TextLayer
        let fontData: Data?
        let pointSize: Double
        /// 씬이 정한 글자 상자(직교 공간). 구운 글자를 여기 맞춰 넣는다.
        let box: SIMD2<Float>
        let origin: SIMD2<Float>
        let queue: DispatchQueue
        let engine: ScriptEngine?
        var value: String
        var texture: MTLTexture?
        var size: SIMD2<Float> = .zero
        /// 이미 돌고 있으면 또 던지지 않는다. 느린 스크립트가 큐에 쌓이면
        /// 나중엔 몇 분 전 시각을 그리게 된다.
        var inFlight = false
        /// 컴포지터 레이어 목록에서의 자리. 글자 폭이 바뀌면 그 자리의 쿼드를 고쳐야 한다.
        var layerIndex = 0

        init(text: TextLayer, fontData: Data?, pointSize: Double, origin: SIMD2<Float>,
             box: SIMD2<Float>, engine: ScriptEngine?, name: String) {
            self.text = text
            self.fontData = fontData
            self.pointSize = pointSize
            self.box = box
            self.origin = origin
            self.engine = engine
            self.value = text.value
            self.queue = DispatchQueue(label: "wallflow.script.\(name)", qos: .utility)
        }
    }

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

    /// `alpha`/`visible` 스크립트를 돌려 표시 상태를 정한다.
    ///
    /// 여러 스크립트가 붙어 있으면 가장 숨기는 쪽을 따른다. 이 위젯들은 조건이
    /// 맞지 않을 때 자기를 감추는 용도라, 하나라도 숨기라면 숨기는 것이 의도에 맞다.
    private static func applyDisplayScripts(
        _ layer: SceneLayer, degraded: inout [String]
    ) -> SceneLayer {
        guard !layer.displayScripts.isEmpty else { return layer }
        var alpha = layer.alpha
        var visible = layer.visible
        var ran = false
        for source in layer.displayScripts {
            let engine = ScriptEngine(source: source)
            // 콜백 전용 스크립트에는 update가 없다. 그건 실패가 아니다 —
            // 미디어 위젯은 이벤트로만 동작한다. 본문 평가 실패만 건너뛴다.
            if case .evaluationFailed = engine.failure { continue }
            guard let state = engine.runLayerCallbacks(
                initial: LayerScriptState(alpha: layer.alpha, visible: layer.visible))
            else { continue }
            alpha = Swift.min(alpha, state.alpha)
            visible = visible && state.visible
            ran = true
        }
        guard ran else {
            degraded.append("\(layer.name): 표시 스크립트를 돌리지 못해 저장된 값으로 그린다")
            return layer
        }
        return SceneLayer(
            id: layer.id, name: layer.name, visible: visible,
            origin: layer.origin, size: layer.size, content: layer.content,
            unrunScripts: layer.unrunScripts, alpha: alpha, tint: layer.tint,
            rotation: layer.rotation, displayScripts: layer.displayScripts)
    }

    /// 소리 파일을 찾아 재생기를 만든다.
    ///
    /// 파일을 임시 디스크에 풀지 않는다. `AVAudioPlayer(data:)`가 메모리에서 바로 읽는다.
    /// macOS는 mp3와 wav를 네이티브로 읽고 ogg는 못 읽는다 — 보유한 씬에서
    /// 140개 중 138개가 mp3/wav다. 못 읽는 것은 이유를 남긴다.
    private static func makePlayer(
        _ sound: SoundLayer, resolver: ReferenceResolver
    ) -> AVAudioPlayer? {
        for path in sound.paths {
            guard let data = resolver.data(for: path),
                  let player = try? AVAudioPlayer(data: data) else { continue }
            player.volume = Float(sound.volume)
            // -1이면 무한 반복이다.
            player.numberOfLoops = sound.loops ? -1 : 0
            player.prepareToPlay()
            return player
        }
        return nil
    }

    /// 소리 설정과 재생 상태를 맞춘다.
    func applySoundSetting() {
        let on = Self.soundEnabled && !playbackPaused
        var failed = 0
        for player in sounds {
            if on, !player.isPlaying {
                if !player.play() { failed += 1 }
            } else if !on, player.isPlaying {
                player.pause()
            }
        }
        guard !sounds.isEmpty else { return }
        let playing = sounds.filter(\.isPlaying).count
        // 소리가 안 난다는 신고를 받았을 때 어디까지 갔는지 알 수 있어야 한다.
        // 시작한 개수가 아니라 지금 나는 개수를 남긴다 — 이미 나던 것도 세야
        // "안 난다"와 "이미 나고 있다"를 구별할 수 있다.
        var line = "씬 \(item.title)의 소리 \(sounds.count)개 중 \(playing)개 재생 중"
        line += " (설정 \(Self.soundEnabled ? "켬" : "끔")"
        line += playbackPaused ? ", 전력 정책이 멈춤)" : ")"
        if failed > 0 { line += " — \(failed)개는 재생을 시작하지 못했다" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// 글자를 굽고 텍스처와 쿼드 크기를 갱신한다.
    /// 직교 공간과 픽셀이 1:1이라 구운 이미지 크기를 그대로 쿼드 크기로 쓴다.
    private func rasterize(_ state: TextState, compositor: MetalCompositor) {
        guard let image = try? TextRasterizer.rasterize(
            text: state.value, fontData: state.fontData,
            pointSize: state.pointSize, color: state.text.color)
        else {
            // 빈 문자열이면 텍스처를 지운다. 이전 글자가 남으면 시계가 멈춘 것처럼 보인다.
            state.texture = nil
            state.size = .zero
            return
        }
        state.texture = try? compositor.makeTexture(from: .image(image))
        // 구운 글자를 씬이 정한 상자에 비율 그대로 맞춰 넣는다. 상자를 무시하면
        // 글자가 상자를 넘어 화면 밖으로 밀려난다.
        let fitted = TextRasterizer.fit(
            imageWidth: image.width, imageHeight: image.height,
            boxWidth: Double(state.box.x), boxHeight: Double(state.box.y))
        state.size = SIMD2(Float(fitted.width), Float(fitted.height))
    }

    /// 스크립트를 돌려 값이 바뀌었으면 다시 굽는다.
    ///
    /// 스크립트는 레이어의 직렬 큐에서 돌고, 결과만 메인으로 돌아온다. 굽는 것과
    /// 텍스처 업로드는 메인에서 한다(Metal 객체가 메인 격리라서).
    private func runScripts() {
        guard let compositor else { return }
        for state in texts {
            guard let engine = state.engine, !state.inFlight else { continue }
            state.inFlight = true
            let current = state.value
            state.queue.async { [weak self, weak state] in
                let produced = engine.update(value: current)
                Task { @MainActor in
                    guard let self, let state else { return }
                    state.inFlight = false
                    guard let produced, produced != state.value else { return }
                    state.value = produced
                    self.rasterize(state, compositor: compositor)
                    self.refreshLayers()
                }
            }
        }
    }

    /// 글자 폭은 글자 수에 따라 바뀐다. 쿼드를 그대로 두면 "9:59"와 "10:00"이
    /// 같은 상자에 늘어나 붙는다. 바뀐 크기를 레이어 목록에 반영해 다시 준다.
    /// 1초에 한 번 남짓이라 비용이 문제되지 않는다.
    private func refreshLayers() {
        guard let compositor else { return }
        for state in texts where state.layerIndex < layerList.count {
            layerList[state.layerIndex].0 = QuadInstance(
                origin: state.origin, size: state.size,
                color: layerList[state.layerIndex].0.color,
                rotation: layerList[state.layerIndex].0.rotation)
        }
        compositor.setLayers(layerList)
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

        // project.json의 file이 가리키는 이름 그대로 .pkg를 연다. 이름이 늘
        // scene인 것은 아니다 — 실물에 gifscene.pkg인 씬이 있다.
        // mmap을 쓰지 않는다. 이 파일은 SteamCmdClient가 관리하는 워크숍 콘텐츠라
        // 로딩 도중 업데이트가 덮어써 잘리면 매핑이 SIGBUS로 죽는다 — Swift 오류가
        // 아니라 프로세스 종료라 잡을 수 없다. AssetsStore.data(for:)의 판단과 같다.
        let raw = try Data(
            contentsOf: item.packageURL
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
        var texts: [TextState] = []
        var sounds: [AVAudioPlayer] = []
        var drawable: [(QuadInstance, LayerSource)] = []

        for rawLayer in document.layers where rawLayer.visible {
            // 표시 스크립트를 먼저 돌린다. 미디어 위젯이 "지금 재생 중이 아니다"를
            // 알고 스스로 숨는다 — 저장된 alpha로 그리면 반투명한 검은 상자가 남는다.
            let layer = Self.applyDisplayScripts(rawLayer, degraded: &degraded)
            guard layer.visible, layer.alpha > 0.004 else {
                if rawLayer.alpha != layer.alpha || rawLayer.visible != layer.visible {
                    degraded.append("\(layer.name): 스크립트가 숨김으로 정했다")
                }
                continue
            }
            if !layer.unrunScripts.isEmpty {
                // 조용히 무시하면 사용자가 레이어가 왜 안 움직이는지 알 수 없다.
                degraded.append(
                    "\(layer.name): \(layer.unrunScripts.joined(separator: ", "))의 스크립트를 "
                        + "아직 돌리지 못해 저장된 값으로 그린다")
            }
            let quad = QuadInstance(
                origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                size: SIMD2(Float(layer.size.x), Float(layer.size.y)),
                color: SIMD4(Float(layer.tint.x), Float(layer.tint.y), Float(layer.tint.z),
                             Float(layer.alpha)),
                rotation: Float(layer.rotation))

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
                            degraded.append(
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

            case .sound(let sound):
                // 그리지 않는다. 소리만 준비해 둔다.
                guard let player = Self.makePlayer(sound, resolver: resolver) else {
                    skipped.append(
                        "\(layer.name): 재생할 수 없는 소리 형식이다 "
                            + "(\(sound.paths.map { ($0 as NSString).pathExtension }.joined(separator: ", ")))")
                    continue
                }
                // startsilent인 소리는 스크립트가 켜기 전까지 나지 않는다.
                // 스크립트를 아직 돌리지 않으므로 준비만 하고 재생 목록에는 넣지 않는다.
                if sound.startsSilent {
                    degraded.append("\(layer.name): 시작할 때 조용한 소리라 스크립트 없이는 나지 않는다")
                } else {
                    sounds.append(player)
                }

            case .text(let text):
                // 폰트가 없어도 그린다 — 시스템 폰트로 대체된다. 글자가 아예
                // 안 나오는 것보다 다른 폰트로라도 나오는 게 낫다.
                let fontData = text.usesSystemFont ? nil : resolver.data(for: text.fontPath)
                if fontData == nil && !text.usesSystemFont {
                    degraded.append("\(layer.name): 폰트를 찾을 수 없어 시스템 폰트로 그린다: \(text.fontPath)")
                }
                // 오브젝트의 size는 글자 크기가 아니라 **상자**다. 실물에서 411x5300짜리도
                // 있어서 그대로 점 크기로 쓰면 글자가 화면 밖으로 밀려난다. 대신 고정
                // 크기로 굽고 상자에 맞춰 줄인다. 256은 레티나에서 흐리지 않을 만큼 크다.
                let pointSize = 256.0
                let engine = text.script.map {
                    ScriptEngine(
                        source: $0,
                        properties: text.scriptProperties.mapValues(\.jsValue))
                }
                if let failure = engine?.failure {
                    skipped.append("\(layer.name): 스크립트를 쓸 수 없다: \(failure)")
                }
                let state = TextState(
                    text: text, fontData: fontData, pointSize: pointSize,
                    origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                    box: SIMD2(Float(layer.size.x), Float(layer.size.y)),
                    engine: engine?.failure == nil ? engine : nil, name: layer.name)
                texts.append(state)
                // 첫 값을 바로 구워 둔다. 스크립트가 처음 도는 1초 동안 비어 보이면
                // 사용자는 고장으로 읽는다.
                if let engine = state.engine, let first = engine.update(value: state.value) {
                    state.value = first
                }
                rasterize(state, compositor: compositor)
                state.layerIndex = drawable.count
                // 글자 색은 래스터화할 때 이미 칠했다. 여기서 또 곱하면 색이 제곱된다.
                // 틴트는 흰색으로 두고 레이어 투명도만 넘긴다.
                drawable.append((QuadInstance(
                    origin: state.origin, size: state.size,
                    color: SIMD4(1, 1, 1, Float(layer.alpha)),
                    rotation: Float(layer.rotation)),
                    .dynamic { [weak state] in state?.texture }))

            case .unsupported(let reason):
                skipped.append("\(layer.name): \(reason)")
            }
        }
        self.videos = videos
        self.particles = particles
        self.texts = texts
        self.sounds = sounds

        // 건너뛴 이유는 drawable이 비어 폴백하는 경우에 사용자가 가장 필요로 한다.
        // isEmpty 가드보다 먼저 써야 그 경로에서도 진단이 버려지지 않는다.
        if !skipped.isEmpty {
            FileHandle.standardError.write(Data(
                "씬 \(item.title)에서 그리지 못한 레이어 \(skipped.count)개:\n  "
                    .appending(skipped.joined(separator: "\n  "))
                    .appending("\n").utf8
            ))
        }
        if !degraded.isEmpty {
            FileHandle.standardError.write(Data(
                "씬 \(item.title)에서 온전하지 않게 그린 레이어 \(degraded.count)개:\n  "
                    .appending(degraded.joined(separator: "\n  "))
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

        self.layerList = drawable
        compositor.setLayers(drawable)
        self.compositor = compositor

        // 비디오·파티클·텍스트는 모두 시간에 따라 바뀐다.
        if !videos.isEmpty || !particles.isEmpty || !texts.isEmpty {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            // 전력 정책이 30fps를 지시한다. 60fps 소스라도 그 이상 그리지 않는다.
            view.preferredFramesPerSecond = PowerPolicy.normalFPS
        }

        view.needsDisplay = true
        // 뷰의 재생 상태가 정해진 뒤에 소리를 맞춘다. 먼저 부르면 아직 정지
        // 상태로 보여 아무것도 재생되지 않는다.
        applySoundSetting()
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            // 뷰를 숨기지 않는다. 마지막 프레임이 남아야 검은 화면이 되지 않는다.
            // 정적 씬은 애초에 그릴 것이 없어 이 분기가 아무 일도 하지 않는다.
            playbackPaused = true
            for video in videos { video.pause() }
            applySoundSetting()
            view?.isPaused = true
            // 다시 재생할 때 멈춰 있던 시간이 통째로 적분되지 않게 한다.
            // 시뮬레이션이 스스로 죄지만, 여기서 끊어야 파티클이 튀지 않는다.
            lastFrameTime = nil
        case .playing(let fps):
            playbackPaused = false
            view?.isHidden = false
            // VideoRenderer.apply와 맞춘다: 이미 재생 중이면 다시 부르지 않는다.
            for video in videos where !video.isPlaying { video.play() }
            applySoundSetting()
            if !videos.isEmpty || !particles.isEmpty || !texts.isEmpty {
                view?.isPaused = false
                view?.preferredFramesPerSecond = fps
            }
            view?.needsDisplay = true
        }
    }

    func stop() {
        for video in videos { video.stop() }
        videos.removeAll()
        for player in sounds { player.stop() }
        sounds.removeAll()
        particles.removeAll()
        texts.removeAll()
        lastFrameTime = nil
        lastScriptTime = nil
        compositor = nil
        layerList = []
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        if !texts.isEmpty {
            let now = CACurrentMediaTime()
            if lastScriptTime.map({ now - $0 >= Self.scriptInterval }) ?? true {
                lastScriptTime = now
                runScripts()
            }
        }
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
