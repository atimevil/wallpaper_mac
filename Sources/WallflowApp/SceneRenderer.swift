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
    private var particles: [(system: ParticleSystem,
                             groups: [String: (ParticleRenderer, Float)])] = []
    /// 직전 프레임 시각. 첫 프레임에는 없다.
    private var lastFrameTime: CFTimeInterval?
    /// 텍스트 레이어마다 스크립트와 구운 글자. 값이 바뀔 때만 다시 굽는다.
    private var texts: [TextState] = []
    /// `visible`/`alpha` 스크립트를 계속 돌려야 하는 레이어들.
    ///
    /// 한 번만 돌려서는 안 된다. 실물 음악 위젯의 진행 막대는 0.5초짜리 타이머가
    /// 끝나야 "재생 중인 음악이 없다"로 판단해 숨는다 — 처음에는 보이라고 답한다.
    private var displays: [DisplayState] = []
    /// 레이어에 걸린 이펙트 체인들. 매 프레임 컴포지터보다 먼저 그린다.
    private var effectChains: [(chain: EffectChain, source: MTLTexture)] = []
    /// 이펙트가 쓰는 `g_Time`. 씬을 켠 뒤 흐른 시간이다.
    private var effectStartTime: CFTimeInterval?
    /// 화면 전체 후처리. 입력이 "합성이 끝난 화면"이라 첫 프레임에야 만들 수 있다.
    private var postEffects: EffectChain?
    private var postEffectSource: SceneLayer?
    private var postShaderIncludes: [String: String] = [:]
    private var postResolver: ReferenceResolver?
    /// 합성 레이어들. 입력이 "그 지점까지 그려진 화면"이라 첫 프레임에야 체인을 만든다.
    private var compositionLayers: [Int: SceneLayer] = [:]
    private var compositionChains: [Int: EffectChain] = [:]
    private var compositionResolver: ReferenceResolver?
    private var compositionIncludes: [String: String] = [:]
    /// 스크립트를 마지막으로 돌린 시각. 시계는 초 단위로 바뀌므로 1초에 한 번이면 된다.
    private var lastScriptTime: CFTimeInterval?
    /// 스크립트를 다시 돌리는 주기.
    private static let scriptInterval: CFTimeInterval = 1.0
    /// 씬이 정한 시차 강도. 0이면 이 씬은 시차를 쓰지 않는다.
    private var parallaxAmount: Double = 0
    /// 부드럽게 따라가는 현재 밀림. 마우스로 바로 튀면 눈에 거슬린다.
    private var parallaxOffset = SIMD2<Float>(0, 0)
    /// 씬의 직교 공간 크기. 시차 밀림을 그 단위로 계산한다.
    private var ortho = SIMD2<Float>(1, 1)
    /// 이 씬의 소리들. 사용자가 켤 때만 실제로 난다.
    private var sounds: [(player: AVAudioPlayer, sceneVolume: Float)] = []
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

    static let volumeKey = "wallflow.soundVolume"

    /// 씬 소리의 크기(0~1). **씬이 정한 볼륨에 곱한다** — 씬마다 제 나름의 균형이
    /// 있어서, 사용자 설정으로 그것을 덮어쓰면 원래 작게 깔린 소리가 튄다.
    ///
    /// 저장된 값이 없으면 100%다. 값은 파일이 아니라 우리 설정에서 오지만,
    /// 손으로 고칠 수 있으니 0~1로 죈다.
    static var soundVolume: Double {
        guard let stored = UserDefaults.standard.object(forKey: volumeKey) as? Double,
              stored.isFinite else { return 1 }
        return Swift.min(Swift.max(stored, 0), 1)
    }
    /// 컴포지터에 준 레이어 목록. 글자 크기가 바뀌면 다시 줘야 해서 들고 있는다.
    private var layerList: [(QuadInstance, LayerSource)] = []

    @MainActor
    /// 표시 스크립트가 붙은 레이어 하나의 살아 있는 상태.
    /// 엔진을 유지해야 스크립트 안의 타이머와 플래그가 호출 사이에 남는다.
    private final class DisplayState {
        let scripts: [(property: DisplayScript.Property, engine: ScriptEngine)]
        let layerIndex: Int
        let baseAlpha: Double
        let baseVisible: Bool
        /// 마지막으로 화면에 반영한 알파. 안 바뀌면 레이어 목록을 다시 올리지 않는다.
        var applied: Float

        init(scripts: [(property: DisplayScript.Property, engine: ScriptEngine)],
             layerIndex: Int, baseAlpha: Double, baseVisible: Bool, applied: Float) {
            self.scripts = scripts
            self.layerIndex = layerIndex
            self.baseAlpha = baseAlpha
            self.baseVisible = baseVisible
            self.applied = applied
        }
    }

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
        /// 상자 안에서의 가로 정렬. 글자 폭이 바뀌면 붙는 자리도 달라진다.
        let align: TextAlignment
        let verticalAlign: TextVerticalAlignment
        /// 상자의 중심. 정렬에 따라 실제 그리는 중심이 이것과 달라진다.
        let boxCenter: SIMD2<Float>
        let queue: DispatchQueue
        let engine: ScriptEngine?
        var value: String
        var texture: MTLTexture?
        var size: SIMD2<Float> = .zero
        /// 실제로 그리는 중심. 정렬 때문에 상자 중심과 다를 수 있다.
        var origin: SIMD2<Float>
        /// 이미 돌고 있으면 또 던지지 않는다. 느린 스크립트가 큐에 쌓이면
        /// 나중엔 몇 분 전 시각을 그리게 된다.
        var inFlight = false
        /// 컴포지터 레이어 목록에서의 자리. 글자 폭이 바뀌면 그 자리의 쿼드를 고쳐야 한다.
        var layerIndex = 0

        init(text: TextLayer, fontData: Data?, pointSize: Double, origin: SIMD2<Float>,
             box: SIMD2<Float>, engine: ScriptEngine?, name: String) {
            self.align = text.horizontalAlign
            self.verticalAlign = text.verticalAlign
            self.boxCenter = origin
            self.origin = origin
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
        _ layer: SceneLayer, degraded: inout [String],
        environment: SceneScriptRuntime.Environment, modules: [String: String]
    ) -> SceneLayer {
        guard !layer.displayScripts.isEmpty else { return layer }
        var alpha = layer.alpha
        var visible = layer.visible
        var ran = false
        for script in layer.displayScripts {
            let engine = ScriptEngine(source: script.source,
                                      environment: environment, modules: modules)
            // 콜백 전용 스크립트에는 update가 없다. 그건 실패가 아니다 —
            // 미디어 위젯은 이벤트로만 동작한다. 본문 평가 실패만 건너뛴다.
            if case .evaluationFailed = engine.failure { continue }
            if let state = engine.runLayerCallbacks(
                initial: LayerScriptState(alpha: layer.alpha, visible: layer.visible)) {
                alpha = Swift.min(alpha, state.alpha)
                visible = visible && state.visible
                ran = true
            }
            // 콜백만이 아니라 `update(value)`도 돌린다. 실물 진행 막대는
            // 콜백이 아니라 update에서 "재생 중이 없으니 숨어라"를 돌려준다.
            switch script.property {
            case .visible:
                if let shown = engine.update(value: layer.visible, frametime: 0) {
                    visible = visible && shown
                    ran = true
                }
            case .alpha:
                if let a = engine.update(value: layer.alpha, frametime: 0) {
                    alpha = Swift.min(alpha, Swift.min(Swift.max(a, 0), 1))
                    ran = true
                }
            }
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
        let volume = Float(Self.soundVolume)
        var failed = 0
        for (player, sceneVolume) in sounds {
            // 크기는 켜고 끌 때마다 다시 맞춘다. 설정이 바뀌는 경로가 이것뿐이다.
            player.volume = sceneVolume * volume
            if on, !player.isPlaying {
                if !player.play() { failed += 1 }
            } else if !on, player.isPlaying {
                player.pause()
            }
        }
        guard !sounds.isEmpty else { return }
        let playing = sounds.filter { $0.player.isPlaying }.count
        // 소리가 안 난다는 신고를 받았을 때 어디까지 갔는지 알 수 있어야 한다.
        // 시작한 개수가 아니라 지금 나는 개수를 남긴다 — 이미 나던 것도 세야
        // "안 난다"와 "이미 나고 있다"를 구별할 수 있다.
        var line = "씬 \(item.title)의 소리 \(sounds.count)개 중 \(playing)개 재생 중"
        line += " (설정 \(Self.soundEnabled ? "켬" : "끔"), 크기 "
            + "\(Int((Self.soundVolume * 100).rounded()))%"
        line += playbackPaused ? ", 전력 정책이 멈춤)" : ")"
        if failed > 0 { line += " — \(failed)개는 재생을 시작하지 못했다" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// 마우스 위치를 따라 레이어를 조금씩 민다.
    ///
    /// 화면 중심에서 얼마나 떨어졌는지를 -1~1로 재고, 씬이 정한 강도와 레이어의
    /// 깊이를 곱한다. 바로 따라가면 눈에 거슬려서 프레임마다 조금씩 좁힌다.
    private func updateParallax(in view: MTKView) {
        guard parallaxAmount > 0, let window = view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let mouse = NSEvent.mouseLocation
        // 화면 중심 기준 -1~1. 화면 밖이면 가장자리로 죈다.
        let nx = Float(min(max((mouse.x - frame.midX) / (frame.width / 2), -1), 1))
        // 마우스 y는 위가 크고 씬 좌표도 위가 크므로 부호를 그대로 쓴다.
        let ny = Float(min(max((mouse.y - frame.midY) / (frame.height / 2), -1), 1))
        let target = SIMD2(nx, ny) * Float(parallaxAmount) * ortho * 0.05
        // 지수 평활. 프레임률이 달라져도 비슷한 속도로 따라간다.
        parallaxOffset += (target - parallaxOffset) * 0.12
        compositor?.setParallax(parallaxOffset)
    }

    /// 글자를 굽고 텍스처와 쿼드 크기를 갱신한다.
    /// 직교 공간과 픽셀이 1:1이라 구운 이미지 크기를 그대로 쿼드 크기로 쓴다.
    private func rasterize(_ state: TextState, compositor: MetalCompositor) {
        // 씬이 정한 줄바꿈 폭은 씬 단위다. 우리는 고정 크기로 구우므로 비율로 옮긴다.
        // pointsize는 크기 결정이 아니라 이 비율에만 쓴다 — 씬의 편집기 값이라
        // 그대로 크기로 쓰면 실제 렌더와 어긋난다.
        let wrap = state.text.wrapping
        let wrapWidth = wrap.maxWidth > 0 && wrap.pointSize > 0
            ? wrap.maxWidth * state.pointSize / wrap.pointSize : 0
        guard let image = try? TextRasterizer.rasterize(
            text: state.value, fontData: state.fontData,
            pointSize: state.pointSize, color: state.text.color,
            wrapWidth: wrapWidth, maxRows: wrap.maxRows, usesEllipsis: wrap.usesEllipsis,
            shadow: state.text.shadow,
            // 그림자 오프셋도 씬 단위라 줄바꿈 폭과 같은 비율로 옮긴다.
            shadowScale: wrap.pointSize > 0 ? state.pointSize / wrap.pointSize : 1)
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
        // 정렬은 **origin을 기준점으로** 글자의 어느 쪽을 붙이는지다. 상자 기준으로
        // 잡으면 안 된다 — 실물 Chisa 씬의 시계는 상자가 화면 오른쪽 밖(3886 > 3840)
        // 까지 나가 있어서, 상자 오른쪽에 붙이면 초 자리가 잘린다.
        switch state.align {
        case .left: state.origin.x = state.boxCenter.x + state.size.x / 2
        case .right: state.origin.x = state.boxCenter.x - state.size.x / 2
        case .center: state.origin.x = state.boxCenter.x
        }
        // 세로도 같은 규칙이다. 씬 좌표는 Y가 위로 증가하므로 top은 더하는 쪽이다.
        switch state.verticalAlign {
        case .top: state.origin.y = state.boxCenter.y - state.size.y / 2
        case .bottom: state.origin.y = state.boxCenter.y + state.size.y / 2
        case .center: state.origin.y = state.boxCenter.y
        }
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

    /// 이펙트 체인을 켤지. **기본은 꺼짐이다.**
    ///
    /// 번역기·이펙트 해석·유니폼 배치는 검증됐지만, 패스가 소스 텍스처를 샘플링한
    /// 결과에 아직 자홍색 블록이 섞인다. 파이프라인·바인딩·합성은 정상임을
    /// 확인했다(슬롯에 흰색을 묶으면 흰색이, 샘플링을 상수로 바꾸면 그 색이
    /// 화면 전체에 제대로 나온다). 원인은 그 사이 어딘가다.
    ///
    /// 15패스 체인(블러+갓레이+물흐름+구름+물결)이 걸린 실물 씬을 미리보기와
    /// 비교해 일치를 확인했고, 배경화면 26개를 순회해 죽는 씬도 평평해지는 씬도
    /// 없었다(이펙트를 끈 것과 픽셀 분포가 같다).
    ///
    /// 문제가 생기면 `WALLFLOW_EFFECTS=0`으로 끄고 원본만 그린다.
    static var effectsEnabled: Bool {
        ProcessInfo.processInfo.environment["WALLFLOW_EFFECTS"] != "0"
    }

    /// 지금 듣고 있는 소리의 대역 크기. 앱 전체가 하나를 공유한다 —
    /// 화면이 여럿이어도 시스템 소리는 하나다.
    static var audioSource: AudioSpectrum?

    static var audioBands: [Int: (left: [Float], right: [Float])] {
        // 진단용: 스펙트럼을 고정값으로 채운다. 씬 자체 애니메이션과 섞이지 않아
        // 비주얼라이저가 실제로 그려지는지만 가려낼 수 있다.
        if let forced = ProcessInfo.processInfo.environment["WALLFLOW_AUDIO_TEST"],
           let level = Float(forced) {
            var out: [Int: (left: [Float], right: [Float])] = [:]
            for resolution in AudioSpectrum.resolutions {
                // 대역마다 다른 높이를 줘야 막대 모양이 보인다.
                let ramp = (0..<resolution).map { level * Float($0 + 1) / Float(resolution) }
                out[resolution] = (ramp, ramp)
            }
            return out
        }
        return audioSource?.bands ?? [:]
    }

    /// 이펙트 체인을 그린다. 컴포지터의 커맨드 버퍼에 같이 실린다.
    ///
    /// 움직이지 않는 이펙트는 **한 번만** 그린다. 배경화면은 상시 구동이라,
    /// 결과가 같은 그림을 매 프레임 다시 그리는 것은 그대로 낭비다.
    private func renderEffects(into commands: MTLCommandBuffer) {
        guard !effectChains.isEmpty else { return }
        let now = CACurrentMediaTime()
        let start = effectStartTime ?? now
        let isFirstFrame = effectStartTime == nil
        effectStartTime = start
        let time = Float(now - start)
        let bands = Self.audioBands
        for entry in effectChains where entry.chain.isAnimated || isFirstFrame || !bands.isEmpty {
            entry.chain.audioBands = bands
            entry.chain.render(commandBuffer: commands, source: entry.source, time: time)
        }
    }

    /// 합성 레이어 하나를 그린다. 그 지점까지 그려진 화면이 입력이다.
    private func renderComposition(
        _ id: Int, commands: MTLCommandBuffer, frame: MTLTexture
    ) -> MTLTexture? {
        guard let layer = compositionLayers[id], let resolver = compositionResolver,
              let device = compositor?.device else { return nil }
        if compositionChains[id] == nil {
            var ignored: [String] = []
            guard let chain = EffectChain(
                device: device,
                effects: layer.effects.map(\.definition),
                effectBases: layer.effects.map(\.base),
                source: frame, resolver: resolver, includes: compositionIncludes,
                makeTexture: { [weak self] in
                    guard let compositor = self?.compositor else {
                        throw RendererError.noDrawableLayers
                    }
                    return try compositor.makeTexture(from: $0)
                },
                diagnostics: &ignored) else {
                // 한 번 실패하면 매 프레임 다시 시도하지 않는다.
                compositionLayers[id] = nil
                FileHandle.standardError.write(Data(
                    "\(layer.name): 합성 레이어의 이펙트를 걸지 못했다\n".utf8))
                return nil
            }
            compositionChains[id] = chain
        }
        guard let chain = compositionChains[id] else { return nil }
        let now = CACurrentMediaTime()
        let start = effectStartTime ?? now
        effectStartTime = start
        chain.audioBands = Self.audioBands
        chain.render(commandBuffer: commands, source: frame, time: Float(now - start))
        return chain.texture
    }

    /// 합성이 끝난 화면에 후처리를 건다.
    ///
    /// 체인은 입력 텍스처가 있어야 만들 수 있는데 화면 크기는 그릴 때 정해진다.
    /// 그래서 첫 프레임에 만든다. 실패하면 nil을 돌려 원래 화면을 그대로 쓴다.
    private func renderPostProcess(
        _ commands: MTLCommandBuffer, frame: MTLTexture
    ) -> MTLTexture? {
        guard let layer = postEffectSource, let resolver = postResolver,
              let device = compositor?.device else { return nil }
        if postEffects == nil {
            var ignored: [String] = []
            postEffects = EffectChain(
                device: device,
                effects: layer.effects.map(\.definition),
                effectBases: layer.effects.map(\.base),
                source: frame, resolver: resolver, includes: postShaderIncludes,
                makeTexture: { [weak self] in
                    guard let compositor = self?.compositor else {
                        throw RendererError.noDrawableLayers
                    }
                    return try compositor.makeTexture(from: $0)
                },
                diagnostics: &ignored)
            if postEffects == nil {
                // 한 번 실패하면 매 프레임 다시 시도하지 않는다.
                postEffectSource = nil
                FileHandle.standardError.write(Data(
                    "후처리 레이어의 이펙트를 걸지 못해 화면을 그대로 낸다\n".utf8))
                return nil
            }
        }
        guard let chain = postEffects else { return nil }
        let now = CACurrentMediaTime()
        let start = effectStartTime ?? now
        effectStartTime = start
        chain.audioBands = Self.audioBands
        chain.render(commandBuffer: commands, source: frame, time: Float(now - start))
        return chain.texture
    }

    /// 이펙트가 그림을 그릴 흰 판. 도형 레이어에는 원본 그림이 없다.
    ///
    /// 크기는 레이어 크기를 따르되 상한을 지킨다 — 상시 구동 앱에서 큰 판을
    /// 잡을 이유가 없고, 어차피 화면 크기로 줄여 보인다.
    private static func makeBlankTexture(
        width: Double, height: Double, compositor: MetalCompositor
    ) -> MTLTexture? {
        let cap = Double(EffectChain.maxWorkingSide)
        let longest = Swift.max(width, height)
        let divisor = longest > cap ? longest / cap : 1
        let pixelWidth = Int((width / divisor).rounded())
        let pixelHeight = Int((height / divisor).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let bytes = [UInt8](repeating: 255, count: pixelWidth * pixelHeight * 4)
        return try? compositor.makeTexture(from: .pixels(
            bytes: Data(bytes), width: pixelWidth, height: pixelHeight, format: .rgba8888))
    }

    /// 셰이더가 `#include`로 부르는 헤더들을 모은다.
    ///
    /// 헤더는 pkg에도 assets에도 있다. 한쪽만 보면 `ApplyBlending` 같은 공용 함수를
    /// 못 찾아 그 셰이더가 통째로 컴파일에 실패한다 — 실물에서 13개가 이 때문에
    /// 떨어졌다. 이름은 마지막 경로 조각과 전체 경로 둘 다로 등록한다.
    private static func collectShaderHeaders(
        reader: PkgReader, assets: AssetsStore?
    ) -> [String: String] {
        var includes: [String: String] = [:]
        if let assets {
            let root = assets.root.appendingPathComponent("shaders")
            if let walker = FileManager.default.enumerator(atPath: root.path) {
                for case let path as String in walker where path.hasSuffix(".h") {
                    guard let body = try? String(
                        contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                    else { continue }
                    includes[(path as NSString).lastPathComponent] = body
                    includes[path] = body
                }
            }
        }
        // pkg의 헤더가 assets의 같은 이름을 이긴다. 씬이 가져온 것이 그 씬의 것이다.
        for name in reader.names where name.hasSuffix(".h") {
            guard let data = try? reader.data(for: name),
                  let body = String(data: data, encoding: .utf8) else { continue }
            includes[(name as NSString).lastPathComponent] = body
            includes[name] = body
        }
        return includes
    }

    /// 표시 스크립트를 다시 돌려 알파를 갱신한다.
    ///
    /// 렌더 스레드에서 돈다. 글자 스크립트와 달리 결과가 한 실수뿐이라 굽는 비용이
    /// 없고, 1초에 한 번이라 무한 루프 위험도 그만큼 낮다. 대신 결과가 바뀐 것이
    /// 하나도 없으면 레이어 목록을 다시 올리지 않는다.
    ///
    /// - Parameter elapsed: 지난 호출 이후 실제로 흐른 시간(초).
    ///   스크립트의 타이머가 이 값으로 흐른다.
    private func runDisplayScripts(elapsed: Double) {
        guard let compositor, !displays.isEmpty else { return }
        var changed = false
        for state in displays where state.layerIndex < layerList.count {
            var alpha = state.baseAlpha
            var visible = state.baseVisible
            for (property, engine) in state.scripts {
                switch property {
                case .visible:
                    if let shown = engine.update(value: state.baseVisible, frametime: elapsed) {
                        visible = visible && shown
                    }
                case .alpha:
                    if let a = engine.update(value: state.baseAlpha, frametime: elapsed) {
                        alpha = Swift.min(alpha, Swift.min(Swift.max(a, 0), 1))
                    }
                }
            }
            let wanted = visible ? Float(alpha) : 0
            guard abs(wanted - state.applied) > 0.002 else { continue }
            state.applied = wanted
            layerList[state.layerIndex].0.color.w = wanted
            changed = true
        }
        if changed { compositor.setLayers(layerList) }
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
    /// 파티클 하나와 그 자식들의 렌더러를 만든다.
    ///
    /// 키는 `ParticleSystem.renderableGroups`와 같은 규칙을 쓴다 — 뿌리가 `"0"`,
    /// 자식이 `"0.<차례>"`. 두 곳이 같은 규칙을 쓰지 않으면 자식이 조용히
    /// 안 그려진다. 텍스처를 못 읽은 자식은 건너뛰고 나머지는 그대로 그린다.
    private static func buildParticleRenderers(
        preset: ParticlePreset, texturePath: String, blend: ParticleBlendMode,
        key: String, instances: Int, layer: SceneLayer, compositor: MetalCompositor,
        resolver: ReferenceResolver,
        into out: inout [(key: String, renderer: ParticleRenderer, ratio: Float)],
        skipped: inout [String]
    ) {
        guard let raw = resolver.data(for: texturePath) else {
            skipped.append("\(layer.name): 파티클 텍스처를 찾을 수 없다: \(texturePath)")
            return
        }
        do {
            let decoded = try TexDecoder.decode(raw)
            guard case .video = decoded else {
                let texture = try compositor.makeTexture(from: decoded)
                // 빌보드가 찌그러지지 않게 세로를 보정한다.
                let ratio = texture.width > 0
                    ? Float(texture.height) / Float(texture.width) : 1
                // 같은 정의에서 나온 여러 벌이 한 렌더러를 함께 쓴다. 그만큼 자리를
                // 잡아 두지 않으면 나중에 터진 불꽃이 잘려 나간다.
                let capacity = min(preset.maxCount * max(1, instances),
                                   ParticlePreset.maxAllowedCount)
                let renderer = try compositor.makeParticleRenderer(
                    maxCount: capacity, blend: blend, texture: texture,
                    layerOrigin: SIMD3(Float(layer.origin.x), Float(layer.origin.y),
                                       Float(layer.origin.z)),
                    layerScale: SIMD3(Float(layer.scale.x), Float(layer.scale.y),
                                      Float(layer.scale.z)),
                    sheet: Self.spriteSheet(of: raw),
                    animationMode: preset.animationMode)
                out.append((key, renderer, ratio))
                for (index, child) in preset.children.enumerated() {
                    buildParticleRenderers(
                        preset: child.preset, texturePath: child.texturePath,
                        blend: child.blend, key: key + ".\(index)",
                        instances: instances * max(1, child.reference.maxCount),
                        layer: layer, compositor: compositor, resolver: resolver,
                        into: &out, skipped: &skipped)
                }
                return
            }
            skipped.append("\(layer.name): 파티클 텍스처가 비디오다: \(texturePath)")
        } catch {
            skipped.append("\(layer.name): 파티클 텍스처 로드 실패 \(error)")
        }
    }

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
        view.colorPixelFormat = MetalCompositor.colorPixelFormat
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
        parallaxAmount = document.parallaxAmount
        ortho = SIMD2(Float(document.orthoWidth), Float(document.orthoHeight))
        if document.clearEnabled {
            compositor.setClearColor(MTLClearColor(
                red: document.clearColor.x, green: document.clearColor.y,
                blue: document.clearColor.z, alpha: 1
            ))
        }

        let resolver = ReferenceResolver(pkg: reader, assets: assets)
        // 셰이더가 `#include "common.h"` 하는 헤더들. pkg와 assets 양쪽에 있다.
        // 안 모으면 `ApplyBlending` 같은 공용 함수를 못 찾아 컴파일이 통째로 실패한다.
        let shaderIncludes = Self.collectShaderHeaders(reader: reader, assets: assets)
        var chains: [(chain: EffectChain, source: MTLTexture)] = []

        var videos: [VideoTexture] = []
        var particles: [(system: ParticleSystem,
                         groups: [String: (ParticleRenderer, Float)])] = []
        var texts: [TextState] = []
        var sounds: [(player: AVAudioPlayer, sceneVolume: Float)] = []
        var drawable: [(QuadInstance, LayerSource)] = []
        var displayStates: [DisplayState] = []
        var postLayers: [SceneLayer] = []
        var compositions: [Int: SceneLayer] = [:]
        // 스크립트가 화면·캔버스 크기를 물어본다(실물에서 `engine.screenResolution` 13회).
        // 없으면 참조 오류로 스크립트가 통째로 죽는다.
        let screen = view.window?.screen ?? NSScreen.main
        let scriptEnvironment = SceneScriptRuntime.Environment(
            screenWidth: Double(screen?.frame.width ?? CGFloat(document.orthoWidth)),
            screenHeight: Double(screen?.frame.height ?? CGFloat(document.orthoHeight)),
            canvasWidth: Double(document.orthoWidth),
            canvasHeight: Double(document.orthoHeight))

        for rawLayer in document.layers where rawLayer.visible {
            // 표시 스크립트를 먼저 돌린다. 미디어 위젯이 "지금 재생 중이 아니다"를
            // 알고 스스로 숨는다 — 저장된 alpha로 그리면 반투명한 검은 상자가 남는다.
            let layer = Self.applyDisplayScripts(
                rawLayer, degraded: &degraded,
                environment: scriptEnvironment, modules: document.scriptModules)
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
                rotation: Float(layer.rotation),
                parallaxDepth: Float(layer.parallaxDepth))

            // 표시 스크립트는 한 번으로 끝나지 않는다. 진행 막대는 타이머가 끝나야
            // 숨기라고 답하므로, 엔진을 살려 두고 주기적으로 다시 묻는다.
            if !layer.displayScripts.isEmpty {
                let engines = layer.displayScripts.compactMap {
                    script -> (property: DisplayScript.Property, engine: ScriptEngine)? in
                    let engine = ScriptEngine(source: script.source,
                                              environment: scriptEnvironment,
                                              modules: document.scriptModules)
                    if case .evaluationFailed = engine.failure { return nil }
                    if case .noUpdateFunction = engine.failure { return nil }
                    return (script.property, engine)
                }
                if !engines.isEmpty {
                    displayStates.append(DisplayState(
                        scripts: engines, layerIndex: drawable.count,
                        baseAlpha: layer.alpha, baseVisible: layer.visible,
                        applied: Float(layer.alpha)))
                }
            }

            switch layer.content {
            case .composition:
                // 합성 레이어는 그 지점까지 그려진 화면이 입력이라, 체인을 여기서
                // 만들 수 없다(화면 텍스처가 아직 없다). 자리만 잡아 두고
                // 첫 프레임에 만든다. 오디오 막대가 이 형태다.
                guard !layer.effects.isEmpty, Self.effectsEnabled else {
                    degraded.append("\(layer.name): 합성 레이어인데 걸 이펙트가 없다")
                    continue
                }
                compositions[drawable.count] = layer
                drawable.append((quad, .composition(drawable.count)))

            case .postProcess:
                // 화면 전체 후처리. 다른 레이어처럼 그리지 않는다 — 합성이 끝난
                // 화면을 입력으로 받아야 해서, 컴포지터가 마지막에 따로 부른다.
                postLayers.append(layer)

            case .solidColor(let c):
                // 도형 레이어는 그림이 없고 이펙트가 그림을 만든다(실물 빛줄기).
                // 흰 판을 만들어 체인에 넣고 그 결과를 그린다.
                if !layer.effects.isEmpty, Self.effectsEnabled,
                   let blank = Self.makeBlankTexture(
                    width: layer.size.x, height: layer.size.y, compositor: compositor),
                   let chain = EffectChain(
                    device: device,
                    effects: layer.effects.map(\.definition),
                    effectBases: layer.effects.map(\.base),
                    source: blank, resolver: resolver,
                    includes: shaderIncludes,
                    makeTexture: { try compositor.makeTexture(from: $0) },
                    diagnostics: &degraded) {
                    chains.append((chain, blank))
                    drawable.append((quad, .dynamic { [weak chain] in chain?.texture }))
                } else {
                    drawable.append((quad, .solid(SIMD4(Float(c.x), Float(c.y), Float(c.z), 1))))
                }

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
                        // 이펙트가 걸려 있으면 그 결과를 대신 그린다. 컴파일이 안 되면
                        // 체인이 nil이라 원본을 그대로 쓴다 — 레이어를 버리지 않는다.
                        // 씬 전체 예산을 넘으면 더 걸지 않는다. 레이어는 원본으로 그린다.
                        let effectBudgetLeft = chains.reduce(0) { $0 + $1.chain.textureBytes }
                            < EffectChain.maxSceneTextureBytes
                        if !layer.effects.isEmpty, Self.effectsEnabled, effectBudgetLeft,
                           let chain = EffectChain(
                            device: device,
                            effects: layer.effects.map(\.definition),
                            effectBases: layer.effects.map(\.base),
                            source: texture, resolver: resolver,
                            includes: shaderIncludes,
                            makeTexture: { try compositor.makeTexture(from: $0) },
                            diagnostics: &degraded) {
                            chains.append((chain, texture))
                            drawable.append((quad, .dynamic { [weak chain] in chain?.texture }))
                        } else {
                            if !layer.effects.isEmpty, Self.effectsEnabled {
                                if !effectBudgetLeft {
                                    degraded.append(
                                        "\(layer.name): 씬의 이펙트 텍스처 예산을 넘어 "
                                            + "원본 그대로 그린다")
                                }
                                degraded.append(
                                    "\(layer.name): 이펙트 \(layer.effects.count)개를 걸지 못해 "
                                        + "원본 그대로 그린다")
                            }
                            drawable.append((quad, .fixed(texture)))
                        }
                    }
                } catch {
                    skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
                }

            case .particle(let preset, let texturePath, let blend):
                // 자식까지 한 번에 만든다. 자식 파티클은 부모와 **다른 텍스처와
                // 다른 혼합**을 쓴다(불꽃 잔해는 가산, 빗줄기 꼬리는 반투명) —
                // 그래서 렌더러가 그룹마다 하나씩 필요하다.
                var built: [(key: String, renderer: ParticleRenderer, ratio: Float)] = []
                Self.buildParticleRenderers(
                    preset: preset, texturePath: texturePath, blend: blend, key: "0",
                    instances: 1, layer: layer, compositor: compositor, resolver: resolver,
                    into: &built, skipped: &skipped)
                guard let root = built.first, root.key == "0" else {
                    skipped.append("\(layer.name): 파티클 렌더러를 만들지 못했다: \(texturePath)")
                    continue
                }
                // 시드를 레이어 id로 나눠 레이어마다 다른 수열을 쓴다.
                // 같은 시드를 공유하면 눈과 벚꽃이 똑같이 움직인다.
                let system = ParticleSystem(
                    preset: preset,
                    random: SeededRandom(seed: UInt64(bitPattern: Int64(layer.id))))
                if !system.unimplementedOperators.isEmpty {
                    degraded.append(
                        "\(layer.name): 아직 처리하지 않는 연산자 "
                            + system.unimplementedOperators.joined(separator: ", "))
                }
                var groups: [String: (ParticleRenderer, Float)] = [:]
                for entry in built {
                    groups[entry.key] = (entry.renderer, entry.ratio)
                    // 만든 순서대로 그린다 — 부모가 먼저, 자식이 그 위에.
                    drawable.append((quad, .particles(entry.renderer)))
                }
                particles.append((system, groups))

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
                    // 씬이 정한 볼륨을 따로 들고 있어야 사용자 설정을 곱할 수 있다.
                    // AVAudioPlayer는 원래 값을 기억하지 않는다.
                    sounds.append((player, Float(sound.volume)))
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
                        properties: text.scriptProperties.mapValues(\.jsValue),
                        environment: scriptEnvironment,
                        modules: document.scriptModules)
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
                    rotation: Float(layer.rotation),
                    parallaxDepth: Float(layer.parallaxDepth)),
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
        self.displays = displayStates
        if !chains.isEmpty {
            let bytes = chains.reduce(0) { $0 + $1.chain.textureBytes }
            FileHandle.standardError.write(Data(
                ("이펙트 체인 \(chains.count)개, "
                    + "패스 \(chains.reduce(0) { $0 + $1.chain.passCount })개, "
                    + "텍스처 \(bytes / 1_000_000)MB\n").utf8))
        }
        self.effectChains = chains
        self.effectStartTime = nil
        self.postEffects = nil
        self.compositionLayers = compositions
        self.compositionChains = [:]
        self.compositionResolver = resolver
        self.compositionIncludes = shaderIncludes
        if !compositions.isEmpty {
            compositor.composite = { [weak self] id, commands, frame in
                self?.renderComposition(id, commands: commands, frame: frame)
            }
        }
        if let post = postLayers.first, Self.effectsEnabled {
            if postLayers.count > 1 {
                degraded.append("후처리 레이어가 \(postLayers.count)개다. 첫 번째만 건다")
            }
            // 체인은 입력 텍스처가 있어야 만들어진다. 화면 크기는 그릴 때 정해지므로
            // 여기서는 만들지 않고, 첫 프레임에 실제 화면 텍스처로 만든다.
            self.postEffectSource = post
            self.postShaderIncludes = shaderIncludes
            self.postResolver = resolver
        }
        // 이펙트는 컴포지터가 레이어를 합성하기 전에 자기 텍스처를 그려야 한다.
        compositor.prepare = { [weak self] commands in
            MainActor.assumeIsolated { self?.renderEffects(into: commands) }
        }
        if postEffectSource != nil {
            // 손잡이가 이미 메인 격리라 `assumeIsolated`가 필요 없다.
            compositor.postProcess = { [weak self] commands, frame in
                self?.renderPostProcess(commands, frame: frame)
            }
        }
        compositor.setLayers(drawable)
        self.compositor = compositor

        // 비디오·파티클·텍스트는 모두 시간에 따라 바뀐다.
        // 시간을 쓰는 이펙트(`g_Time`)도 마찬가지다 — 빼면 빛줄기가 첫 프레임에
        // 멈춘 채로 남는다. 움직이지 않는 이펙트는 여기 해당하지 않는다.
        let hasAnimatedEffect = chains.contains { $0.chain.isAnimated }
        if !videos.isEmpty || !particles.isEmpty || !texts.isEmpty || hasAnimatedEffect {
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
        for (player, _) in sounds { player.stop() }
        sounds.removeAll()
        particles.removeAll()
        texts.removeAll()
        lastFrameTime = nil
        lastScriptTime = nil
        compositor = nil
        layerList = []
        displays = []
        effectChains = []
        effectStartTime = nil
        postEffects = nil
        postEffectSource = nil
        compositionLayers = [:]
        compositionChains = [:]
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        updateParallax(in: view)
        if !texts.isEmpty || !displays.isEmpty {
            let now = CACurrentMediaTime()
            let since = lastScriptTime.map { now - $0 }
            if since.map({ $0 >= Self.scriptInterval }) ?? true {
                lastScriptTime = now
                runScripts()
                // 첫 호출에는 직전 시각이 없다. 0을 주면 스크립트의 타이머가
                // 영영 안 흐른다 — 진행 막대가 계속 보인다.
                runDisplayScripts(elapsed: since ?? Self.scriptInterval)
            }
        }
        if !particles.isEmpty {
            let now = CACurrentMediaTime()
            // 첫 프레임에는 직전 시각이 없다. 0을 넘기면 시뮬레이션이 그냥 넘어간다.
            let dt = lastFrameTime.map { now - $0 } ?? 0
            lastFrameTime = now
            for entry in particles {
                entry.system.update(deltaTime: dt)
                // 자식이 아직 안 생겼거나 이미 사라진 그룹은 목록에 없다.
                // 그 렌더러는 비워 둬야 마지막 프레임이 화면에 남지 않는다.
                var seen: Set<String> = []
                for group in entry.system.renderableGroups() {
                    guard let target = entry.groups[group.key] else { continue }
                    seen.insert(group.key)
                    target.0.update(particles: group.particles, textureRatio: target.1)
                }
                for (key, target) in entry.groups where !seen.contains(key) {
                    target.0.update(particles: [], textureRatio: target.1)
                }
            }
        }
        compositor?.draw(in: view)
    }
}
