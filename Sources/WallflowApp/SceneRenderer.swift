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
                             groups: [String: (ParticleRenderer, Float)],
                             layerOrigin: SIMD2<Float>)] = []
    /// 직전 프레임 시각. 첫 프레임에는 없다. 파티클과 스프라이트 시트 이미지가
    /// 같이 쓴다 — 하나만 있어도 매 프레임의 dt는 같아야 한다.
    private var lastFrameTime: CFTimeInterval?
    /// 텍스처가 스프라이트 시트인 이미지 레이어. 매 프레임 누적 재생 시간으로
    /// 칸을 고른다. `SceneRenderer.spriteSheet(of:)`(파티클용)와 달리 프레임마다
    /// 정확한 픽셀 사각형이 필요해 `TexHeader.spriteSheet`를 직접 쓴다.
    private struct SpriteSheetImage {
        let layerIndex: Int
        let sheet: TexSpriteSheet
        /// 프레임의 x/y/w/h는 원본 텍스처 픽셀 좌표다. UV로 바꾸려면 실제로 GPU에
        /// 올라간 텍스처의 크기가 있어야 한다 — 헤더의 texWidth/texHeight는 JPEG·PNG
        /// 처럼 디코드된 실제 크기와 다를 수 있다(TexHeaderTests의 TEXB0003 예처럼).
        let textureSize: SIMD2<Float>
        var elapsed: Double = 0
        /// 마지막으로 골랐던 칸. 바뀔 때만 layerList를 갱신하고 compositor에
        /// 다시 알린다 — Loading...은 초당 10번 바뀌지, 60번이 아니다.
        var lastFrame: TexSpriteFrame?
        /// `thisLayer.getTextureAnimation().isPlaying()`. 기본은 재생 중 — 스크립트가
        /// 없는 레이어(Loading...의 배경 같은)는 이 값을 아무도 안 건드려 계속 돈다.
        /// 실물 미디어 버튼(재생/셔플/즐겨찾기)은 init에서 바로 pause()를 부른다.
        var scriptPlaying = true
        /// 스크립트가 마지막으로 `setFrame`한 칸. `applyScriptState`가 이 값과
        /// 다를 때만 elapsed를 옮긴다 — 매 틱 같은 값을 또 불러도(실물 update()가
        /// 그렇게 짜여 있다) 이미 흐르고 있는 재생을 도로 처음으로 되돌리지 않는다.
        var scriptFrame: Int?
    }
    private var spriteSheetImages: [SpriteSheetImage] = []
    /// 텍스트 레이어마다 스크립트와 구운 글자. 값이 바뀔 때만 다시 굽는다.
    private var texts: [TextState] = []
    /// 씬의 스크립트 전부를 돌리는 호스트. 스크립트가 없는 씬이면 nil이다.
    ///
    /// 렌더 스레드에서 돌리지 않는다. 창작마당 코드라 무한 루프가 있을 수 있고
    /// 그것을 중단시킬 공개 API가 없다(SceneScriptHost 참고). 직렬 큐 하나에 가둬
    /// 두면 폭주해도 화면은 계속 돌고 스크립트 값만 마지막 상태에서 멈춘다.
    private var scriptHost: SceneScriptHost?
    private let scriptQueue = DispatchQueue(label: "wallflow.scenescript", qos: .userInteractive)
    /// 이미 돌고 있으면 또 던지지 않는다. 느린 스크립트가 큐에 쌓이면 몇 초 전
    /// 값을 그리게 된다.
    private var scriptInFlight = false
    private var lastScriptTick: CFTimeInterval?
    /// 글자 굽기 전용 큐. 메인에서 CoreText와 텍스처 업로드를 직접 하면 매초
    /// 여러 레이어가 바뀌는 씬(Pixels 등)에서 프레임이 56~211ms까지 늘어진다
    /// (`sample`로 확인한 값). `scriptQueue`와 굳이 큐를 나누는 이유: 스크립트가
    /// 폭주해도(창작마당 코드라 무한 루프가 있을 수 있다) 글자 굽기는 영향받지
    /// 않아야 한다. 직렬이라 굽기 자체도 한 번에 하나씩만 돈다.
    private let textRasterQueue = DispatchQueue(label: "wallflow.textraster", qos: .userInteractive)
    /// 레이어 id → 마지막으로 화면에 반영한 스크립트 상태. 같으면 손대지 않는다.
    private var appliedStates: [Int: SceneScriptHost.LayerState] = [:]
    /// 레이어 id → 그 레이어의 쿼드·파티클·글자·소리가 어디 있는지.
    private var scriptTargets: [Int: ScriptTarget] = [:]
    /// 스크립트가 만들려 했지만 만들 수 없던 레이어. 매 틱 다시 시도하지 않는다.
    private var unspawnable: Set<Int> = []
    /// 이미 알린 스크립트 오류. 같은 줄을 매 프레임 찍지 않는다.
    private var reportedFailures: Set<String> = []
    /// 씬을 열 때 이미 stderr에 쓴 진단의 수. 그 뒤에 생긴 것만 다시 쓴다.
    private var reportedSkipped = 0
    private var reportedDegraded = 0
    private var buildContext: BuildContext?
    /// 레이어 id → 부모 id. 스크립트가 부모를 숨기면 자식도 숨긴다.
    private var parentOf: [Int: Int] = [:]
    /// 레이어에 걸린 이펙트 체인들. 매 프레임 컴포지터보다 먼저 그린다.
    private var effectChains: [(chain: EffectChain, source: MTLTexture)] = []
    /// 이펙트가 쓰는 `g_Time`. 씬을 켠 뒤 흐른 시간이다.
    private var effectStartTime: CFTimeInterval?
    /// 화면 전체 후처리. 입력이 "합성이 끝난 화면"이라 첫 프레임에야 만들 수 있다.
    private var postEffects: EffectChain?
    private var postEffectSource: SceneLayer?
    /// 씬을 열 때 모아 둔 후처리 레이어들. 첫 번째만 건다.
    private var postLayers: [SceneLayer] = []
    private var postShaderIncludes: [String: String] = [:]
    private var postResolver: ReferenceResolver?
    /// 합성 레이어들. 입력이 "그 지점까지 그려진 화면"이라 첫 프레임에야 체인을 만든다.
    private var compositionLayers: [Int: SceneLayer] = [:]
    private var compositionChains: [Int: EffectChain] = [:]
    private var compositionResolver: ReferenceResolver?
    private var compositionIncludes: [String: String] = [:]
    /// 씬이 정한 시차 강도. 0이면 이 씬은 시차를 쓰지 않는다.
    private var parallaxAmount: Double = 0
    /// 부드럽게 따라가는 현재 밀림. 마우스로 바로 튀면 눈에 거슬린다.
    private var parallaxOffset = SIMD2<Float>(0, 0)
    /// 씬의 직교 공간 크기. 시차 밀림을 그 단위로 계산한다.
    private var ortho = SIMD2<Float>(1, 1)
    /// 원근 씬의 카메라. 직교 씬이면 nil이다. 스크립트가 움직일 수 있어 변수다.
    private var camera: SceneCamera?
    /// 이 씬의 소리들. 사용자가 켤 때만 실제로 난다.
    private var sounds: [SoundEntry] = []
    /// 퍼펫 워프 레이어들. 매 프레임 뼈대를 움직여 정점을 다시 쓴다.
    private var puppets: [PuppetRenderer] = []
    /// 진단용: 프레임 간격 통계를 stderr에 쓴다. "끊긴다"는 말을 수치로 바꾼다.
    private static let frameDebug = ProcessInfo.processInfo.environment["WALLFLOW_FRAME_DEBUG"] != nil
    private var frameIntervals: [Double] = []
    private var lastDrawTime: CFTimeInterval?
    private var puppetStartTime: CFTimeInterval?

    /// 소리 하나. `wanted`는 씬이나 스크립트가 지금 나기를 바라는지다 —
    /// `startsilent`인 소리는 스크립트가 `play()`를 부르기 전까지 false다.
    private final class SoundEntry {
        let player: AVAudioPlayer
        var sceneVolume: Float
        var wanted: Bool
        init(player: AVAudioPlayer, sceneVolume: Float, wanted: Bool) {
            self.player = player
            self.sceneVolume = sceneVolume
            self.wanted = wanted
        }
    }

    /// 레이어를 만들 때 필요한 것들. 스크립트가 나중에 레이어를 만들 때도 같은 것을 쓴다.
    private struct BuildContext {
        let device: MTLDevice
        let compositor: MetalCompositor
        let resolver: ReferenceResolver
        let shaderIncludes: [String: String]
        let isPerspective: Bool
        let canvas: Vec2
        /// 씬의 지운 색. 메시 셰이더의 반사 버퍼 자리에 들어간다.
        let clearColor: SIMD4<Float>
        let ambient: SIMD3<Float>
        let skylight: SIMD3<Float>
    }

    /// 스크립트 상태를 화면의 어디에 반영할지.
    private struct ScriptTarget {
        /// `layerList`에서 이 레이어의 쿼드들. 파티클은 그룹마다 하나다.
        var indices: [Int] = []
        /// 배율을 곱하기 전의 크기. 스크립트의 scale은 여기에 곱한다.
        var baseSize: Vec2
        var brightness: Float
        /// 메시·파티클은 자기 좌표가 이미 세계 단위라 크기를 곱하지 않는다.
        var unitWorld = false
        /// 부모 사슬의 변환. 스크립트는 **부모 기준** 값을 쓰므로(`thisLayer.origin`은
        /// 오브젝트 자체의 origin) 여기에 합쳐야 화면 자리가 된다. 실물 시계 위젯이
        /// 그룹 안에 있어서, 이걸 빼먹으면 첫 틱에 위젯이 화면 구석으로 튄다.
        var parentOrigin = Vec3(x: 0, y: 0, z: 0)
        var parentScale = Vec3(x: 1, y: 1, z: 1)
        /// 라디안.
        var parentRotation = 0.0
        /// `alignment` 닻에서 그림 중심까지. 스크립트의 origin은 닻 자리다.
        var anchorOffset = Vec2(x: 0, y: 0)
        var particleIndex: Int?
        var textIndex: Int?
        var soundIndex: Int?

        /// 스크립트가 준 부모 기준 값을 화면(씬) 값으로 합친다.
        /// `SceneDocument.resolveTransforms`의 compose와 같은 식이다.
        func composed(origin: Vec3, angles: Vec3, scale: Vec3)
            -> (origin: Vec3, anglesDegrees: Vec3, scale: Vec3) {
            let sx = origin.x * parentScale.x, sy = origin.y * parentScale.y
            let c = cos(parentRotation), s = sin(parentRotation)
            let o = Vec3(x: parentOrigin.x + sx * c - sy * s,
                         y: parentOrigin.y + sx * s + sy * c,
                         z: parentOrigin.z + origin.z * parentScale.z)
            let sc = Vec3(x: parentScale.x * scale.x, y: parentScale.y * scale.y,
                          z: parentScale.z * scale.z)
            let a = Vec3(x: angles.x, y: angles.y, z: angles.z + parentRotation * 180 / .pi)
            let total = a.z * .pi / 180
            let ct = cos(total), st = sin(total)
            let drawn = Vec3(x: o.x + anchorOffset.x * ct - anchorOffset.y * st,
                             y: o.y + anchorOffset.x * st + anchorOffset.y * ct, z: o.z)
            return (drawn, a, sc)
        }
    }

    /// 레이어의 합쳐진 값과 자체 값에서 부모 사슬의 변환을 되짚는다.
    private static func parentTransform(of layer: SceneLayer)
        -> (origin: Vec3, scale: Vec3, rotation: Double) {
        func ratio(_ composed: Double, _ local: Double) -> Double {
            abs(local) > 1e-9 ? composed / local : 1
        }
        let scale = Vec3(x: ratio(layer.scale.x, layer.localScale.x),
                         y: ratio(layer.scale.y, layer.localScale.y),
                         z: ratio(layer.scale.z, layer.localScale.z))
        let rotation = layer.rotation - layer.angles.z * .pi / 180
        let sx = layer.localOrigin.x * scale.x, sy = layer.localOrigin.y * scale.y
        let c = cos(rotation), sn = sin(rotation)
        // 합쳐진 origin에는 닻 거리가 더해져 있다. 빼고 되짚는다.
        let ct = cos(layer.rotation), st = sin(layer.rotation)
        let anchorX = layer.anchorOffset.x * ct - layer.anchorOffset.y * st
        let anchorY = layer.anchorOffset.x * st + layer.anchorOffset.y * ct
        let origin = Vec3(x: layer.origin.x - anchorX - (sx * c - sy * sn),
                          y: layer.origin.y - anchorY - (sx * sn + sy * c),
                          z: layer.origin.z - layer.localOrigin.z * scale.z)
        return (origin, scale, rotation)
    }
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
        var boxCenter: SIMD2<Float>
        /// 스크립트가 `pointsize`를 바꾼 비율. 구운 글자 크기에 곱한다.
        var pointScale: Float = 1
        var value: String
        var texture: MTLTexture?
        var size: SIMD2<Float> = .zero
        /// 실제로 그리는 중심. 정렬 때문에 상자 중심과 다를 수 있다.
        var origin: SIMD2<Float>
        /// 구운 픽셀 하나가 씬 단위로 몇인지. 저장된 글자와 상자를 견줘 한 번만
        /// 정한다. 실행 중 글자가 길어져도 글자 크기는 그대로여야 한다.
        var unitsPerPixel: Double?
        /// 배율을 이미 구해 봤는지. 못 구한 경우를 매 프레임 다시 시도하지 않는다.
        var measuredScale = false
        /// 컴포지터 레이어 목록에서의 자리. 글자 폭이 바뀌면 그 자리의 쿼드를 고쳐야 한다.
        var layerIndex = 0
        /// 이 레이어의 백그라운드 굽기 요청 조율기. 늦게 끝난 결과를 버리는 것과
        /// (예: 굽는 도중 빈 문자열로 바뀐 경우) 굽기 속도보다 빠르게 바뀌는
        /// 글자가 큐를 무한정 늘리지 않게 막는 것, 둘 다 `TextBakeCoalescer`(Kit,
        /// 순수 상태 기계 — 단위 테스트가 있다)가 판정한다.
        var bake = TextBakeCoalescer()
        /// 원근 씬에서 이 글자 판의 세계 자리·각도. 직교 씬이면 쓰지 않는다.
        /// 스크립트가 매 틱 갱신해 둔다 — 굽기가 백그라운드에서 도는 동안에도
        /// 레이어가 움직일 수 있어서, 끝난 시점엔 굽기 시작 시점이 아니라 이
        /// 최신 값으로 자리를 잡아야 텍스트가 옛 자리로 튀지 않는다.
        var worldOrigin: Vec3
        var worldAngles: Vec3

        init(text: TextLayer, fontData: Data?, pointSize: Double, origin: SIMD2<Float>,
             box: SIMD2<Float>, worldOrigin: Vec3, worldAngles: Vec3) {
            self.align = text.horizontalAlign
            self.verticalAlign = text.verticalAlign
            self.boxCenter = origin
            self.origin = origin
            self.text = text
            self.fontData = fontData
            self.pointSize = pointSize
            self.box = box
            self.origin = origin
            self.value = text.value
            self.worldOrigin = worldOrigin
            self.worldAngles = worldAngles
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

    /// 사용자가 바꾼 속성값이 사는 곳. 라이브러리 폴더와 따로 둔다 — 그쪽은
    /// "지우기"가 통째로 지우고, 설정은 다시 받아도 남아야 한다.
    static let propertyStore = UserPropertyStore(
        root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Properties"))

    /// 스크립트의 `applyUserProperties`에 줄 값. project.json의 기본값 위에
    /// 사용자가 설정 창에서 바꾼 값을 얹는다.
    static func userPropertyValues(for item: WallpaperItem) -> [String: UserPropertyValue] {
        var values: [String: UserPropertyValue] = [:]
        if let data = try? Data(contentsOf: item.directory.appendingPathComponent("project.json")) {
            for property in UserProperty.load(projectJSON: data) {
                values[property.name] = property.defaultValue
            }
        }
        // 프리셋 값이 기본값을 덮고, 사용자가 바꾼 값이 그 위에 온다.
        for (name, value) in item.presetValues { values[name] = value }
        for (name, value) in propertyStore.overrides(for: item.id) { values[name] = value }
        return values
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
        for entry in sounds {
            let player = entry.player
            // 크기는 켜고 끌 때마다 다시 맞춘다. 설정이 바뀌는 경로가 이것뿐이다.
            player.volume = entry.sceneVolume * volume
            if on, entry.wanted, !player.isPlaying {
                if !player.play() { failed += 1 }
            } else if !(on && entry.wanted), player.isPlaying {
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

    /// 메뉴에서 이 씬이 보여 주는 배경화면의 화면 맞춤 방식을 바꿨을 때 부른다.
    /// 씬을 다시 열지 않고 바로 적용한다.
    func setCanvasFit(_ mode: CanvasFit.Mode) {
        compositor?.setCanvasFit(mode)
        view?.needsDisplay = true
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

    /// 원근 씬이면 카메라를 매 프레임 넘긴다. 화면 비율은 뷰에서 온다.
    private func updateCamera(in view: MTKView) {
        guard let camera else { return }
        let size = view.drawableSize
        let aspect = size.height > 0 ? Double(size.width / size.height) : 16.0 / 9.0
        compositor?.setCamera(
            viewProjection: camera.viewProjection(aspect: aspect),
            eye: SIMD3(Float(camera.eye.x), Float(camera.eye.y), Float(camera.eye.z)))
    }

    /// 마우스 커서를 씬의 직교 좌표로 옮긴다. 화면 밖이면 가장자리로 죈다.
    ///
    /// 씬 좌표는 y가 위로 증가하고 `NSEvent.mouseLocation`도 그러므로 부호를
    /// 그대로 쓴다. 파티클 좌표계는 레이어 기준이라 부르는 쪽에서 원점을 뺀다.
    ///
    /// 화면 비율(0~1)을 캔버스 좌표로 옮기는 건 `quad_vertex`가 하는 NDC 매핑의
    /// 역이다 — 채우기로 잘린 캔버스라면 화면 비율 전체가 캔버스의 일부에만
    /// 대응해야 커서가 화면에 보이는 그림과 맞게 움직인다.
    private func sceneCursorPosition(in view: MTKView) -> SIMD2<Float>? {
        guard let screen = view.window?.screen ?? NSScreen.main,
              let compositor else { return nil }
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let mouse = NSEvent.mouseLocation
        let nx = Double(min(max((mouse.x - frame.minX) / frame.width, 0), 1))
        let ny = Double(min(max((mouse.y - frame.minY) / frame.height, 0), 1))
        let point = compositor.visibleRect.canvasPoint(atScreenFraction: SIMD2(nx, ny))
        return SIMD2(Float(point.x), Float(point.y))
    }

    /// 글자를 굽고 텍스처와 쿼드 크기를 갱신한다. **동기**로 메인에서 굽는다 —
    /// 레이어를 처음 세울 때 한 번만 부르는 경로라(`addLayer`), 매초 여러 번
    /// 도는 스크립트 틱과 달리 여기서 메인이 잠깐 CoreText를 도는 것은 문제가
    /// 되지 않는다. 틱마다 바뀌는 글자는 `rasterizeAsync`를 쓴다.
    /// 직교 공간과 픽셀이 1:1이라 구운 이미지 크기를 그대로 쿼드 크기로 쓴다.
    private func rasterize(_ state: TextState, compositor: MetalCompositor) {
        let wrapWidth = Self.wrapWidth(for: state)
        guard let image = try? TextRasterizer.rasterize(
            text: state.value, fontData: state.fontData,
            pointSize: state.pointSize, color: state.text.color,
            wrapWidth: wrapWidth, maxRows: state.text.wrapping.maxRows,
            usesEllipsis: state.text.wrapping.usesEllipsis,
            shadow: state.text.shadow,
            shadowScale: Self.shadowScale(for: state),
            extraPadding: state.text.padding,
            horizontalAlign: state.align, blockAlign: state.text.blockAlign)
        else {
            // 빈 문자열이면 텍스처를 지운다. 이전 글자가 남으면 시계가 멈춘 것처럼 보인다.
            state.texture = nil
            state.size = .zero
            return
        }
        state.texture = try? compositor.makeTexture(from: .image(image))
        applyRasterizedSize(state, pixelWidth: image.width, pixelHeight: image.height,
                            wrapWidth: wrapWidth)
    }

    /// 값이 바뀐 글자를 백그라운드 큐에서 굽는다. 직렬 큐라 한 번에 하나씩만
    /// 돌고, 끝난 결과는 메인 액터에서만 반영한다 — Metal 텍스처는 메인 격리다.
    ///
    /// 메인에서 직접 CoreText를 굽고 `MTKTextureLoader`로 올리면(예전 방식) 매초
    /// 여러 레이어가 바뀌는 씬(Pixels 등)에서 프레임이 56~211ms까지 늘어진다
    /// (`sample`로 확인한 값). 굽기 자체를 큐로 미루고 픽셀만 받아 온다.
    private func rasterizeAsync(_ state: TextState) {
        let isEmpty = state.value.isEmpty || state.value.allSatisfy(\.isWhitespace)
        // 판정은 전부 `TextBakeCoalescer`가 한다 — 여기서는 그 결정을 따를 뿐이다.
        // (1) 빈 글자는 굽지 않고 바로 지운다. (2) 이미 굽는 중이면 새로 큐에
        // 넣지 않는다 — 시계처럼 굽기 속도보다 빠르게 바뀌는 글자가 큐를
        // 무한정 늘리는 것을 막는다. `dirty`는 엣지 트리거라(`state.value`가
        // 이미 새 값으로 바뀐 뒤 불린다) 건너뛴 요청은 다시 오지 않으므로,
        // 그냥 무시하는 대신 굽기가 끝나는 시점에 다시 구우라고 표시해 둔다.
        switch state.bake.start(isEmpty: isEmpty) {
        case .clear:
            state.texture = nil
            state.size = .zero
            refreshLayers()
            return
        case .wait:
            return
        case .bake(let token):
            startBackgroundBake(state, token: token)
        }
    }

    /// 실제로 CoreText를 돌려 굽는다. `rasterizeAsync`가 `TextBakeCoalescer`로부터
    /// "지금 구워라"를 받았을 때만, 그리고 `finish(token:)`가 `.rebake`를 돌려줘
    /// 다시 구울 때도 이 경로로 온다.
    private func startBackgroundBake(_ state: TextState, token: UInt64) {
        let wrapWidth = Self.wrapWidth(for: state)
        // CoreText 작업은 메인 밖(다른 스레드)에서 돈다. `TextState`는
        // `@MainActor`라 그 안의 값을 배경 큐에서 직접 읽으면 안 되므로, 필요한
        // 값을 전부 여기서(메인 액터) 미리 꺼내 Sendable 값 타입으로 넘긴다 —
        // String·Data?·Double·Vec3·TextShadow?·Vec2·TextAlignment·Bool 전부
        // Sendable이다.
        let value = state.value
        let fontData = state.fontData
        let pointSize = state.pointSize
        let color = state.text.color
        let maxRows = state.text.wrapping.maxRows
        let usesEllipsis = state.text.wrapping.usesEllipsis
        let shadow = state.text.shadow
        let shadowScale = Self.shadowScale(for: state)
        let padding = state.text.padding
        let align = state.align
        let blockAlign = state.text.blockAlign
        textRasterQueue.async { [weak self, weak state] in
            // `TextPixelBuffer`는 Sendable(Data 기반 값 타입)이라 이 경계를
            // 넘을 수 있다 — CGImage였다면(Swift 6에서 Sendable이 아니다) 여기서
            // 컴파일이 막혔을 것이다.
            let buffer = try? TextRasterizer.rasterizePixels(
                text: value, fontData: fontData, pointSize: pointSize, color: color,
                wrapWidth: wrapWidth, maxRows: maxRows, usesEllipsis: usesEllipsis,
                shadow: shadow, shadowScale: shadowScale, extraPadding: padding,
                horizontalAlign: align, blockAlign: blockAlign)
            Task { @MainActor in
                guard let self, let state else { return }
                switch state.bake.finish(token: token) {
                case .rebake:
                    // 굽는 동안 값이 또 바뀌었다 — 지금 든 결과는 버리고 최신
                    // 값을 다시 읽어 한 번 더 굽는다. `rasterizeAsync`가 최신
                    // `state.value`를 다시 읽으므로 여기서 값을 따로 넘기지 않는다.
                    self.rasterizeAsync(state)
                case .stale:
                    break
                case .apply:
                    self.applyRasterResult(buffer, to: state, wrapWidth: wrapWidth)
                }
            }
        }
    }

    /// 백그라운드에서 구운 픽셀을 메인에서 텍스처에 올리고 판 크기를 다시 잰다.
    ///
    /// 텍스처는 **매번 새로 만든다.** 기존 텍스처를 `replace`로 덮으면, 그것을
    /// 읽는 이전 프레임의 커맨드 버퍼가 GPU에서 아직 도는 중일 수 있다 — Metal은
    /// 그 진행 상황을 알려주지 않으므로(진행 중 추적이 없다), 우리가 덮어쓰면
    /// 화면이 찢어지거나 프레임이 섞여 보일 수 있다. 새로 만들면 이전 텍스처는
    /// 그것을 쓰던 커맨드 버퍼가 끝날 때까지 Metal이 알아서 붙잡아 둔다.
    private func applyRasterResult(_ buffer: TextPixelBuffer?, to state: TextState, wrapWidth: Double) {
        if let buffer, let compositor {
            state.texture = try? compositor.makeTexture(from: buffer)
            applyRasterizedSize(state, pixelWidth: buffer.width, pixelHeight: buffer.height,
                                wrapWidth: wrapWidth)
        } else {
            state.texture = nil
            state.size = .zero
        }
        // 레이어 목록에 새 크기·자리를 반영해야 다음 프레임에 보인다.
        refreshLayers()
    }

    /// 씬이 정한 줄바꿈 폭(씬 단위)을 고정 256pt 래스터 공간의 비율로 옮긴다.
    /// pointsize는 크기 결정이 아니라 이 비율에만 쓴다 — 씬의 편집기 값이라
    /// 그대로 크기로 쓰면 실제 렌더와 어긋난다.
    private static func wrapWidth(for state: TextState) -> Double {
        let wrap = state.text.wrapping
        return wrap.maxWidth > 0 && wrap.pointSize > 0
            ? wrap.maxWidth * state.pointSize / wrap.pointSize : 0
    }

    /// 그림자 오프셋도 씬 단위라 줄바꿈 폭과 같은 비율로 옮긴다.
    private static func shadowScale(for state: TextState) -> Double {
        let wrap = state.text.wrapping
        return wrap.pointSize > 0 ? state.pointSize / wrap.pointSize : 1
    }

    /// 구운 픽셀 크기로 판 크기·자리를 잡는다.
    ///
    /// 동기 경로(레이어를 처음 세울 때)와 비동기 경로(스크립트 틱)가 굽는
    /// 방식만 다르고 이 계산은 완전히 같다 — 여기서 공유해 둘이 갈라지지 않게 한다.
    private func applyRasterizedSize(
        _ state: TextState, pixelWidth: Int, pixelHeight: Int, wrapWidth: Double
    ) {
        // `padding`은 "글자 도형 둘레의 여백"이다(문서). 우리는 고정 256pt로
        // 굽고 그 raster 공간의 픽셀 여백으로 그대로 쓴다 — 씬마다 편집기
        // pointsize가 달라도(9~98) 여백은 항상 같은 비율로 보여야 하고,
        // 실물 값(32 안팎)이 딱 그 정도 raster 여백에 맞는 크기다.
        //
        // 상자는 **편집기에 저장된 글자**의 크기다. 실행 중 글자를 거기 맞추면
        // `Date`(4자)로 저장된 상자에 `07 SEP 2026`(11자)을 우겨넣게 되어 글자가
        // 쪼그라든다. 저장된 글자에서 배율을 한 번 얻어 두고 그 배율로 그린다 —
        // 글자 크기가 고정되고 긴 글자는 상자를 넘어간다. 실물이 그렇다.
        measureTextScale(state, wrapWidth: wrapWidth)
        if let unitsPerPixel = state.unitsPerPixel {
            state.size = SIMD2(Float(Double(pixelWidth) * unitsPerPixel),
                               Float(Double(pixelHeight) * unitsPerPixel))
        } else {
            // 저장된 글자를 못 재면 예전처럼 상자에 맞춘다.
            let fitted = TextRasterizer.fit(
                imageWidth: pixelWidth, imageHeight: pixelHeight,
                boxWidth: Double(state.box.x), boxHeight: Double(state.box.y))
            state.size = SIMD2(Float(fitted.width), Float(fitted.height))
        }
        state.size *= state.pointScale
        // 스크립트가 만든 글자는 얼마든지 길어질 수 있다. 화면 몇 배를 넘으면
        // 그리기가 의미 없고 텍스처만 커지므로 거기서 죈다.
        let cap = ortho * 4
        if state.size.x > cap.x || state.size.y > cap.y, state.size.x > 0, state.size.y > 0 {
            let shrink = Swift.min(cap.x / state.size.x, cap.y / state.size.y)
            state.size *= shrink
        }
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

    /// 저장된 글자를 같은 조건으로 한 번 구워 상자와의 배율을 잡는다.
    ///
    /// 저장된 글자가 비어 있거나 굽지 못하면 배율 없이 둔다 — 그때는 상자에
    /// 맞추는 예전 방식으로 그린다.
    private func measureTextScale(_ state: TextState, wrapWidth: Double) {
        guard !state.measuredScale else { return }
        state.measuredScale = true
        let authored = state.text.value
        guard !authored.isEmpty, !authored.allSatisfy(\.isWhitespace) else { return }
        let wrap = state.text.wrapping
        guard let image = try? TextRasterizer.rasterize(
            text: authored, fontData: state.fontData,
            pointSize: state.pointSize, color: state.text.color,
            wrapWidth: wrapWidth, maxRows: wrap.maxRows, usesEllipsis: wrap.usesEllipsis,
            shadow: state.text.shadow,
            shadowScale: wrap.pointSize > 0 ? state.pointSize / wrap.pointSize : 1,
            extraPadding: state.text.padding,
            horizontalAlign: state.align, blockAlign: state.text.blockAlign)
        else { return }
        state.unitsPerPixel = TextRasterizer.unitsPerPixel(
            authoredWidth: image.width, authoredHeight: image.height,
            boxWidth: Double(state.box.x), boxHeight: Double(state.box.y))
    }

    /// 스크립트를 돌려 값이 바뀌었으면 다시 굽는다.
    ///
    /// 스크립트는 레이어의 직렬 큐에서 돌고, 결과만 메인으로 돌아온다. 굽는 것과
    /// 텍스처 업로드는 메인에서 한다(Metal 객체가 메인 격리라서).
    /// 스크립트를 한 틱 돌린다. 직렬 큐에서 돌고 결과는 메인에서 반영한다.
    private func tickScripts(in view: MTKView) {
        guard let host = scriptHost, !scriptInFlight else { return }
        let now = CACurrentMediaTime()
        let dt = lastScriptTick.map { now - $0 } ?? 0
        lastScriptTick = now
        let cursor = sceneCursorPosition(in: view).map {
            Vec3(x: Double($0.x), y: Double($0.y), z: 0)
        }
        // 화면 좌표(왼쪽 위 원점, 포인트). `input.cursorScreenPosition`이 된다.
        let screenCursor: Vec2? = (view.window?.screen ?? NSScreen.main).map { screen in
            let mouse = NSEvent.mouseLocation
            let frame = screen.frame
            return Vec2(x: Double(mouse.x - frame.minX), y: Double(frame.maxY - mouse.y))
        }
        // 스크립트가 오디오를 달라고 했을 때만 스펙트럼을 넘긴다. 듣고 있지 않으면
        // 빈 사전이라 버퍼가 0으로 남는다 — 가짜 소리를 지어내지 않는다.
        let audio = host.wantsAudio ? Self.audioBands : [:]
        scriptInFlight = true
        scriptQueue.async { [weak self] in
            let snapshot = host.tick(frametime: dt, cursorWorld: cursor, cursorScreen: screenCursor,
                                     audio: audio)
            Task { @MainActor in
                guard let self else { return }
                self.scriptInFlight = false
                self.apply(snapshot)
            }
        }
    }

    /// 스크립트가 정한 상태를 화면에 옮긴다. 바뀐 레이어만 손댄다.
    private func apply(_ snapshot: SceneScriptHost.Snapshot) {
        guard let compositor else { return }
        var changed = false
        for id in snapshot.order {
            guard var state = snapshot.layers[id] else { continue }
            // 보임은 조상 사슬을 따라 합친다. 실물 픽셀 씬이 창 하나를 숨기면 그 안의
            // 막대·테두리·글자가 전부 따라 사라져야 한다.
            var ancestor = parentOf[id]
            var hops = 0
            while let current = ancestor, hops < 32, state.visible {
                if let parentState = snapshot.layers[current], !parentState.visible {
                    state.visible = false
                }
                ancestor = parentOf[current]
                hops += 1
            }
            if scriptTargets[id] == nil, id < 0, !unspawnable.contains(id) {
                // 스크립트가 만든 레이어. 자산에서 레이어를 세워 목록 끝에 붙인다.
                if let asset = state.asset, spawnLayer(id: id, asset: asset) {
                    changed = true
                } else {
                    unspawnable.insert(id)
                    degraded.append("스크립트가 만든 레이어를 세우지 못했다: \(state.asset ?? "?")")
                }
            }
            guard appliedStates[id] != state else { continue }
            appliedStates[id] = state
            let applied = applyScriptState(state, to: id)
            if Self.scriptDebug {
                let composed = scriptTargets[id].map {
                    $0.composed(origin: state.origin, angles: state.angles, scale: state.scale)
                }
                let line = "SCRIPTDBG \(id) \(state.name) vis=\(state.visible) a=\(state.alpha) "
                    + "o=\(state.origin) world=\(composed.map { "\($0.origin) s=\($0.scale)" } ?? "-") "
                    + "parent=\(scriptTargets[id].map { "\($0.parentOrigin) x\($0.parentScale)" } ?? "-") "
                    + "t=\(state.text.map { String($0.prefix(16)) } ?? "-") p=\(state.playing.map { "\($0)" } ?? "-") applied=\(applied)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            if applied { changed = true }
        }
        if let camera = snapshot.camera { self.camera = camera }
        // 스크립트가 만든 레이어의 진단은 씬을 연 뒤에 생긴다. 그때그때 알린다.
        if skipped.count > reportedSkipped || degraded.count > reportedDegraded {
            let fresh = skipped[reportedSkipped...] + degraded[reportedDegraded...]
            reportedSkipped = skipped.count
            reportedDegraded = degraded.count
            FileHandle.standardError.write(Data(
                "씬 \(item.title)의 스크립트가 만든 레이어 진단:\n  "
                    .appending(fresh.joined(separator: "\n  ")).appending("\n").utf8))
        }
        for failure in snapshot.failures where !reportedFailures.contains(failure) {
            reportedFailures.insert(failure)
            FileHandle.standardError.write(Data("씬 \(item.title) 스크립트 오류: \(failure)\n".utf8))
        }
        if changed { compositor.setLayers(layerList) }
    }

    /// 상태 하나를 레이어의 쿼드·파티클·글자·소리에 옮긴다. 화면이 바뀌면 true.
    private func applyScriptState(_ state: SceneScriptHost.LayerState, to id: Int) -> Bool {
        guard let target = scriptTargets[id], let context = buildContext else { return false }
        var changed = false
        let alpha = state.visible ? Float(state.alpha) : 0
        let world = target.composed(origin: state.origin, angles: state.angles, scale: state.scale)
        for index in target.indices where index < layerList.count {
            var quad = layerList[index].0
            quad.color = SIMD4(
                Float(state.color.x) * target.brightness,
                Float(state.color.y) * target.brightness,
                Float(state.color.z) * target.brightness, alpha)
            if let ti = target.textIndex, ti < texts.count {
                // 글자는 구운 크기가 곧 판의 크기다. 자리는 정렬을 거친 origin이다.
                let text = texts[ti]
                if context.isPerspective {
                    quad.world = Scene3D.world(
                        origin: world.origin, anglesDegrees: world.anglesDegrees,
                        scale: Vec3(x: 1, y: 1, z: 1),
                        size: Vec2(x: Double(text.size.x), y: Double(text.size.y)))
                } else {
                    quad.origin = text.origin
                    quad.size = text.size
                }
            } else if context.isPerspective {
                quad.world = Scene3D.world(
                    origin: world.origin, anglesDegrees: world.anglesDegrees, scale: world.scale,
                    size: target.unitWorld ? Vec2(x: 1, y: 1) : target.baseSize)
            } else {
                quad.origin = SIMD2(Float(world.origin.x), Float(world.origin.y))
                quad.size = SIMD2(Float(target.baseSize.x * world.scale.x),
                                  Float(target.baseSize.y * world.scale.y))
                quad.rotation = Float(world.anglesDegrees.z * .pi / 180)
            }
            layerList[index].0 = quad
            if !state.material.isEmpty, case .model(let renderer) = layerList[index].1 {
                renderer.setConstants(state.material)
            }
            // `thisLayer.getTextureAnimation()`을 부른 스크립트가 있으면(둘은 항상
            // 같이 온다) 재생 여부·못박은 칸을 넘긴다. 실물 미디어 버튼이 이렇게
            // 아이콘 한 칸에 고정된다 — 안 챙기면 시트가 계속 자동으로 넘어간다.
            if let playing = state.textureAnimationPlaying, let frame = state.textureAnimationFrame,
               let j = spriteSheetImages.firstIndex(where: { $0.layerIndex == index }) {
                spriteSheetImages[j].scriptPlaying = playing
                // 매 틱 같은 n으로 다시 불러도(실물 update()가 그렇게 짜여 있다)
                // 여기서 걸러야 재생 위치가 프레임 시작으로 계속 되감기지 않는다.
                // ponytail: setFrame을 한 번도 안 부르고 pause()만 부르는 스크립트가
                // 있다면(실물 3793322447은 init에서 항상 setFrame도 같이 부른다)
                // frame이 기본값 0으로 와서 "지금 있던 자리"가 아니라 0번으로
                // 튄다 — scriptFrame이 nil→0도 "바뀜"으로 본다. 실물로 못 본
                // 경우라 지금은 고르지 않는다. 문제되면 __texAnim에 "frame을
                // 한 번이라도 지정했는지" 플래그를 얹어 그때만 점프하게 한다.
                if spriteSheetImages[j].scriptFrame != frame {
                    spriteSheetImages[j].scriptFrame = frame
                    spriteSheetImages[j].elapsed = spriteSheetImages[j].sheet.startTime(ofFrame: frame)
                }
            }
            changed = true
        }
        // `compositor`는 여기서 다시 안 묶는다 — `apply(_:)`가 이미 최상단에서
        // `guard let compositor`로 확인했다(이 함수는 그 뒤에서만 불린다).
        if let ti = target.textIndex, ti < texts.count {
            let text = texts[ti]
            // 원근 씬에서 굽기가 끝난 뒤(백그라운드라 몇 틱 걸릴 수 있다)에도
            // 최신 자리로 놓으려면 dirty 여부와 무관하게 매 틱 갱신해 둔다 —
            // 텍스트 내용은 그대로여도 레이어 자체가 움직일 수 있다.
            text.worldOrigin = world.origin
            text.worldAngles = world.anglesDegrees
            var dirty = false
            if let value = state.text, value != text.value {
                text.value = value
                dirty = true
            }
            // 스크립트가 origin을 옮기면(실물 `resizeScreen`) 상자 중심도 따라간다.
            let center = SIMD2(Float(world.origin.x), Float(world.origin.y))
            if !context.isPerspective, center != text.boxCenter {
                text.boxCenter = center
                dirty = true
            }
            // `thisObject.pointsize`는 글자 크기다. 저장된 크기와의 비율로 곱한다.
            let authored = text.text.wrapping.pointSize
            if let pointSize = state.pointSize, authored > 0 {
                let scale = Float(pointSize / authored)
                if abs(scale - text.pointScale) > 1e-4 {
                    text.pointScale = scale
                    dirty = true
                }
            }
            if dirty {
                // 굽기는 백그라운드에서 끝난다 — 여기서는 아직 `text.size`/`origin`이
                // 새 값이 아니다. 레이어 목록 갱신은 `applyRasterResult`가
                // `refreshLayers()`로 결과가 오는 대로 따로 한다(이 함수보다 늦게).
                rasterizeAsync(text)
                changed = true
            }
        }
        if let pi = target.particleIndex, pi < particles.count {
            let system = particles[pi].system
            particles[pi].layerOrigin = SIMD2(Float(world.origin.x), Float(world.origin.y))
            // 스크립트의 `layer.instance`. 스폰 결과는 새로 나는 파티클부터 먹는다.
            var instance = system.instance
            instance.apply(state.instance)
            if instance != system.instance {
                system.instance = instance
                changed = true
            }
            // 한 틱 안의 `stop(); play()`는 재시작이다(실물 PS2 오브가 색을 바꾼 뒤
            // 이렇게 다시 튼다). 거둔 뒤 아래 play()가 다시 뿌린다.
            if state.restarts > system.restartsSeen {
                system.restartsSeen = state.restarts
                system.stop()
                changed = true
            }
            // 스크립트의 play()/stop(). 바뀔 때만 — stop()은 파티클을 거두므로 매 틱 부르면 안 된다.
            if let playing = state.playing, playing != system.isPlaying {
                playing ? system.play() : system.stop()
                changed = true
            }
        }
        if let si = target.soundIndex, si < sounds.count {
            let entry = sounds[si]
            if let volume = state.volume { entry.sceneVolume = Float(volume) }
            if let playing = state.playing, playing != entry.wanted {
                entry.wanted = playing
            }
            entry.player.volume = entry.sceneVolume * Float(Self.soundVolume)
            let on = Self.soundEnabled && !playbackPaused && entry.wanted
            if on, !entry.player.isPlaying { _ = entry.player.play() }
            if !on, entry.player.isPlaying { entry.player.pause() }
        }
        return changed
    }

    /// 스크립트가 `createLayer(asset)`으로 만든 레이어를 세운다.
    private func spawnLayer(id: Int, asset: String) -> Bool {
        guard let context = buildContext,
              let layer = SceneDocument.layer(
                fromAsset: asset, id: id, resolver: context.resolver,
                isPerspective: context.isPerspective, canvas: context.canvas)
        else { return false }
        let before = layerList.count
        addLayer(layer, context: context)
        // 새 레이어의 재질에도 상수 스크립트가 있을 수 있다(실물 프리즘의 Alpha·색).
        // 호스트는 자기 큐에서만 만진다.
        let scripts = materialScripts(of: id)
        if !scripts.isEmpty, let host = scriptHost {
            scriptQueue.async { host.attachMaterialScripts(layerID: id, scripts) }
        }
        return scriptTargets[id] != nil || layerList.count > before
    }

    /// 이미지 레이어를 목록에 붙인다. 퍼펫 워프가 있으면 쿼드 대신 메시로 그린다 —
    /// 메시는 쿼드와 같은 자리·크기 안에서 정점만 움직인다.
    private func appendImage(_ quad: QuadInstance, layer: SceneLayer, context: BuildContext,
                             texture: MTLTexture, provider: (@MainActor () -> MTLTexture?)?) {
        if let spec = layer.puppet {
            do {
                guard let raw = context.resolver.data(for: spec.path) else {
                    throw MDLError.truncated("퍼펫 메시가 없다: \(spec.path)")
                }
                let model = try PuppetModel.parse(raw)
                let renderer = try PuppetRenderer(
                    device: context.device, model: model, spec: spec,
                    imageSize: SIMD2(Float(texture.width), Float(texture.height)),
                    texture: provider ?? { [texture] in texture })
                puppets.append(renderer)
                layerList.append((quad, .puppet(renderer)))
                return
            } catch {
                degraded.append("\(layer.name): 퍼펫 워프를 못 읽어 그림만 그린다: \(error)")
            }
        }
        if let provider {
            layerList.append((quad, .dynamic(provider)))
        } else {
            layerList.append((quad, .fixed(texture)))
        }
    }

    /// 레이어의 메시·셰이더 이미지 재질에 붙은 상수 스크립트들.
    private func materialScripts(of id: Int) -> [SceneScriptHost.MaterialScript] {
        guard let target = scriptTargets[id] else { return [] }
        var scripts: [SceneScriptHost.MaterialScript] = []
        for index in target.indices where index < layerList.count {
            if case .model(let renderer) = layerList[index].1 {
                scripts.append(contentsOf: renderer.constantScripts)
            }
        }
        return scripts
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

    /// 지금 소리를 필요로 하는 렌더러들. 화면이 여럿이면 하나라도 필요하면 듣는다.
    private static var audioNeeders: Set<ObjectIdentifier> = []
    /// 필요 여부가 바뀔 때 불린다. `AppCoordinator`가 캡처를 켜고 끈다.
    ///
    /// **소리를 쓰는 씬일 때만 켠다.** 예전에는 앱이 뜰 때 무조건 켰는데, 그러면
    /// 오디오를 전혀 안 쓰는 배경화면에서도 macOS가 화면 녹화 권한을 묻는다
    /// (시스템 오디오 캡처가 그 권한 아래 있다).
    static var audioNeedChanged: ((Bool) -> Void)?

    /// 이 씬이 오디오를 쓰는지. 이펙트 셰이더의 스펙트럼 유니폼이나
    /// 스크립트의 `engine.registerAudioBuffers`가 근거다.
    private func updateAudioNeed() {
        let needed = effectChains.contains { $0.chain.usesAudio }
            || compositionChains.values.contains { $0.usesAudio }
            || (postEffects?.usesAudio ?? false)
            || (scriptHost?.wantsAudio ?? false)
        setAudioNeed(needed)
    }

    private func setAudioNeed(_ needed: Bool) {
        let key = ObjectIdentifier(self)
        let before = Self.audioNeeders.contains(key)
        guard before != needed else { return }
        if needed { Self.audioNeeders.insert(key) } else { Self.audioNeeders.remove(key) }
        Self.audioNeedChanged?(!Self.audioNeeders.isEmpty)
    }

    /// 진단용: 스크립트가 바꾼 레이어 상태를 틱마다 stderr에 쓴다.
    static let scriptDebug = ProcessInfo.processInfo.environment["WALLFLOW_SCRIPT_DEBUG"] != nil

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
            // 합성 체인은 첫 프레임에야 만들어진다. 오디오 비주얼라이저가 대개
            // 이 꼴이라, 여기서 다시 판정해야 소리를 듣기 시작한다.
            updateAudioNeed()
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
            if postEffects != nil { updateAudioNeed() }
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

    /// 글자 상태(`texts`)를 레이어 목록(`layerList`)에 다시 반영한다.
    ///
    /// 글자 폭은 글자 수에 따라 바뀐다. 쿼드를 그대로 두면 "9:59"와 "10:00"이
    /// 같은 상자에 늘어나 붙는다. 백그라운드에서 구운 결과가 메인으로 돌아올
    /// 때마다(`applyRasterResult`) 불러 바뀐 크기·자리를 반영한다.
    ///
    /// ponytail: 글자 레이어 하나가 끝날 때마다 전체 `texts`를 다시 훑는다
    /// (O(글자 레이어 수)). 실물 씬은 많아야 수십 개라 무시할 만하지만, 글자
    /// 레이어가 수백 개인 씬이 나오면 `state.layerIndex` 하나만 갱신하도록 좁혀야 한다.
    private func refreshLayers() {
        guard let compositor else { return }
        // 원근 씬은 자리·크기가 `.world`(4x4 행렬) 하나로 들어간다 — `.origin`/
        // `.size`는 원근 파이프라인이 아예 읽지 않는다(MetalCompositor.draw 참고).
        // 씬 전체가 원근이냐 직교냐는 레이어마다 다르지 않으므로 한 번만 본다.
        let isPerspective = buildContext?.isPerspective ?? false
        for state in texts where state.layerIndex < layerList.count {
            guard isPerspective else {
                // 자리와 크기만 갈아 끼운다. 통째로 새로 만들면 시차·섞는 방식처럼
                // 여기 안 적은 값이 조용히 기본값으로 되돌아간다.
                layerList[state.layerIndex].0.origin = state.origin
                layerList[state.layerIndex].0.size = state.size
                continue
            }
            // `worldOrigin`/`worldAngles`는 스크립트가 매 틱 갱신해 둔 최신 값이다
            // (굽기가 도는 동안에도 레이어가 움직일 수 있어서, 굽기 시작 시점이
            // 아니라 끝난 시점의 최신 자리를 써야 한다).
            layerList[state.layerIndex].0.world = Scene3D.world(
                origin: state.worldOrigin, anglesDegrees: state.worldAngles,
                scale: Vec3(x: 1, y: 1, z: 1),
                size: Vec2(x: Double(state.size.x), y: Double(state.size.y)))
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
        normalPath: String?, refractAmount: Double,
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
                // 굴절이면 법선 지도를 함께 올린다. 못 읽으면 굴절만 포기하고
                // 파티클은 그대로 그린다 — 레이어 전체를 버리는 것보다 낫다.
                var normalMap: MTLTexture?
                if let normalPath {
                    if let raw = resolver.data(for: normalPath),
                       let decoded = try? TexDecoder.decode(raw),
                       case .video = decoded {
                        skipped.append("\(layer.name): 굴절 법선 지도가 비디오다: \(normalPath)")
                    } else if let raw = resolver.data(for: normalPath),
                              let decoded = try? TexDecoder.decode(raw),
                              let loaded = try? compositor.makeTexture(from: decoded) {
                        normalMap = loaded
                    } else {
                        skipped.append(
                            "\(layer.name): 굴절 법선 지도를 읽지 못해 휘지 않게 그린다: "
                                + normalPath)
                    }
                }
                let renderer = try compositor.makeParticleRenderer(
                    maxCount: capacity, blend: blend, texture: texture,
                    layerOrigin: SIMD3(Float(layer.origin.x), Float(layer.origin.y),
                                       Float(layer.origin.z)),
                    layerScale: SIMD3(Float(layer.scale.x), Float(layer.scale.y),
                                      Float(layer.scale.z)),
                    sheet: Self.spriteSheet(of: raw),
                    animationMode: preset.animationMode,
                    normalMap: normalMap, refractAmount: Float(refractAmount))
                out.append((key, renderer, ratio))
                for (index, child) in preset.children.enumerated() {
                    buildParticleRenderers(
                        preset: child.preset, texturePath: child.texturePath,
                        blend: child.blend, normalPath: child.normalPath,
                        refractAmount: child.refractAmount, key: key + ".\(index)",
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

    /// 레이어 하나를 세워 목록 끝에 붙인다. 씬을 열 때와 스크립트가 레이어를
    /// 만들 때 같은 길을 쓴다. 그릴 수 없으면 이유만 남기고 돌아온다.
    private func addLayer(_ layer: SceneLayer, context: BuildContext) {
        let firstIndex = layerList.count
        let particlesBefore = particles.count
        let textsBefore = texts.count
        let soundsBefore = sounds.count
        defer {
            // 스크립트가 이 레이어를 움직일 수 있게 어디에 뭐가 붙었는지 적어 둔다.
            var target = ScriptTarget(
                baseSize: Vec2(x: layer.size.x / Swift.max(layer.scale.x, 1e-9),
                               y: layer.size.y / Swift.max(layer.scale.y, 1e-9)),
                brightness: Float(layer.brightness))
            target.indices = Array(firstIndex..<layerList.count)
            let parent = Self.parentTransform(of: layer)
            target.parentOrigin = parent.origin
            target.parentScale = parent.scale
            target.parentRotation = parent.rotation
            target.anchorOffset = layer.anchorOffset
            switch layer.content {
            case .model, .particle: target.unitWorld = true
            default: break
            }
            if particles.count > particlesBefore { target.particleIndex = particlesBefore }
            if texts.count > textsBefore { target.textIndex = textsBefore }
            if sounds.count > soundsBefore { target.soundIndex = soundsBefore }
            if !target.indices.isEmpty || target.soundIndex != nil {
                scriptTargets[layer.id] = target
            }
        }
        if !layer.unrunScripts.isEmpty {
            // 조용히 무시하면 사용자가 레이어가 왜 안 움직이는지 알 수 없다.
            degraded.append(
                "\(layer.name): \(layer.unrunScripts.joined(separator: ", "))의 스크립트를 "
                    + "아직 돌리지 못해 저장된 값으로 그린다")
        }
        // 밝기는 색에 곱한다. 섞는 방식과 짝이라, 실물 시계는 밝기 5.56에
        // 오버레이로 섞이는 것을 전제로 그 값이다.
        let brightness = Float(layer.brightness)
        var quad = QuadInstance(
            origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
            size: SIMD2(Float(layer.size.x), Float(layer.size.y)),
            color: SIMD4(Float(layer.tint.x) * brightness,
                         Float(layer.tint.y) * brightness,
                         Float(layer.tint.z) * brightness,
                         layer.visible ? Float(layer.alpha) : 0),
            rotation: Float(layer.rotation),
            parallaxDepth: Float(layer.parallaxDepth),
            blendMode: Int32(layer.colorBlendMode))
        if context.isPerspective {
            // 원근 씬에서는 자리·크기가 픽셀이 아니라 세계 단위다. 크기에는
            // 배율이 곱해진다 — 실물 배경 구름이 size 64 × scale 10이다.
            // 직교 경로의 `size`는 배율이 이미 곱해져 있으므로 여기서는
            // 배율을 원본 크기와 함께 따로 넣는다. 파티클은 좌표가 이미
            // 세계 단위라 크기를 곱하지 않는다(size가 0이라 곱하면 사라진다).
            var worldSize = Vec2(x: layer.size.x, y: layer.size.y)
            if case .particle = layer.content { worldSize = Vec2(x: 1, y: 1) }
            quad.world = Scene3D.world(
                origin: layer.origin,
                anglesDegrees: Vec3(x: layer.angles.x, y: layer.angles.y, z: layer.rotation * 180 / .pi),
                scale: Vec3(x: 1, y: 1, z: 1),
                size: worldSize)
        }
        if layer.colorBlendMode != 0, let reason = context.compositor.blendUnavailableReason {
            degraded.append(
                "\(layer.name): 색 섞기(\(layer.colorBlendMode))를 못 걸어 보통으로 그린다: "
                    + reason)
        }

        switch layer.content {
        case .composition:
            // 합성 레이어는 그 지점까지 그려진 화면이 입력이라, 체인을 여기서
            // 만들 수 없다(화면 텍스처가 아직 없다). 자리만 잡아 두고
            // 첫 프레임에 만든다. 오디오 막대가 이 형태다.
            guard !layer.effects.isEmpty, Self.effectsEnabled else {
                degraded.append("\(layer.name): 합성 레이어인데 걸 이펙트가 없다")
                return
            }
            compositionLayers[layerList.count] = layer
            layerList.append((quad, .composition(layerList.count)))

        case .postProcess:
            // 화면 전체 후처리. 다른 레이어처럼 그리지 않는다 — 합성이 끝난
            // 화면을 입력으로 받아야 해서, 컴포지터가 마지막에 따로 부른다.
            postLayers.append(layer)

        case .solidColor(let c):
            // 도형 레이어는 그림이 없고 이펙트가 그림을 만든다(실물 빛줄기).
            // 흰 판을 만들어 체인에 넣고 그 결과를 그린다.
            if !layer.effects.isEmpty, Self.effectsEnabled,
               let blank = Self.makeBlankTexture(
                width: layer.size.x, height: layer.size.y, compositor: context.compositor),
               let chain = EffectChain(
                device: context.device,
                effects: layer.effects.map(\.definition),
                effectBases: layer.effects.map(\.base),
                source: blank, resolver: context.resolver,
                includes: context.shaderIncludes,
                makeTexture: { try context.compositor.makeTexture(from: $0) },
                diagnostics: &degraded) {
                effectChains.append((chain, blank))
                layerList.append((quad, .dynamic { [weak chain] in chain?.texture }))
            } else {
                layerList.append((quad, .solid(SIMD4(Float(c.x), Float(c.y), Float(c.z), 1))))
            }

        case .image(let path), .video(let path):
            guard let raw = context.resolver.data(for: path) else {
                skipped.append("\(layer.name): 텍스처를 찾을 수 없다: \(path)")
                return
            }
            do {
                // 사용자 그림(프리셋의 `files/`)은 .tex가 아니라 보통 파일이다.
                let decoded = path.hasPrefix(ReferenceResolver.externalPrefix)
                    ? try TexDecoder.decodeFile(raw) : try TexDecoder.decode(raw)
                if case .video(let mp4) = decoded {
                    guard mp4.count <= Self.maxVideoPayloadBytes else {
                        skipped.append(
                            "\(layer.name): 비디오 페이로드가 상한(\(Self.maxVideoPayloadBytes) bytes)을 "
                                + "넘는다 (\(mp4.count) bytes)")
                        return
                    }
                    guard videos.count < Self.maxConcurrentVideoLayers else {
                        skipped.append(
                            "\(layer.name): 씬당 비디오 레이어 상한(\(Self.maxConcurrentVideoLayers)개)을 "
                                + "넘어 건너뛴다")
                        return
                    }
                    let video = try VideoTexture(mp4: mp4, device: context.device)
                    // status는 init 직후 대개 .unknown이라 이 검사는 이미 동기적으로
                    // 실패가 확정된 드문 경우만 잡는다. 나머지는 VideoTexture.currentTexture()가
                    // 매 프레임 다시 확인해 stderr에 알린다 (VideoTexture 참고).
                    guard !video.hasFailed else {
                        skipped.append("\(layer.name): 비디오를 재생할 수 없다")
                        return
                    }
                    video.play()
                    videos.append(video)
                    layerList.append((quad, .dynamic { [weak video] in video?.currentTexture() }))
                } else {
                    let texture = try context.compositor.makeTexture(from: decoded)
                    // 텍스처가 스프라이트 시트면(예: "Loading..."의 320x200 GIF 60장을
                    // 3200x1200 한 장에 늘어놓은 배경) 매 프레임 한 칸씩 골라 그린다 —
                    // 안 그러면 격자 전체가 정지 이미지 한 장으로 찍힌다. 파티클과 달리
                    // 격자 규칙(framesPerRow)을 다시 계산하지 않고 프레임 표의 실제
                    // 사각형을 그대로 쓴다 — 칸 크기가 균일하지 않은 시트도 맞는다.
                    if let header = try? TexHeader.parse(raw), let sheet = header.spriteSheet,
                       sheet.frames.count > 1 {
                        spriteSheetImages.append(SpriteSheetImage(
                            layerIndex: layerList.count, sheet: sheet,
                            textureSize: SIMD2(Float(texture.width), Float(texture.height))))
                    }
                    // 이펙트가 걸려 있으면 그 결과를 대신 그린다. 컴파일이 안 되면
                    // 체인이 nil이라 원본을 그대로 쓴다 — 레이어를 버리지 않는다.
                    // 씬 전체 예산을 넘으면 더 걸지 않는다. 레이어는 원본으로 그린다.
                    let effectBudgetLeft = effectChains.reduce(0) { $0 + $1.chain.textureBytes }
                        < EffectChain.maxSceneTextureBytes
                    if !layer.effects.isEmpty, Self.effectsEnabled, effectBudgetLeft,
                       let chain = EffectChain(
                        device: context.device,
                        effects: layer.effects.map(\.definition),
                        effectBases: layer.effects.map(\.base),
                        source: texture, resolver: context.resolver,
                        includes: context.shaderIncludes,
                        makeTexture: { try context.compositor.makeTexture(from: $0) },
                        diagnostics: &degraded) {
                        effectChains.append((chain, texture))
                        appendImage(quad, layer: layer, context: context,
                                    texture: texture, provider: { [weak chain] in chain?.texture })
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
                        appendImage(quad, layer: layer, context: context,
                                    texture: texture, provider: nil)
                    }
                }
            } catch {
                skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
            }

        case .particle(let preset, let texturePath, let blend, let normalPath, let refractAmount):
            // 자식까지 한 번에 만든다. 자식 파티클은 부모와 **다른 텍스처와
            // 다른 혼합**을 쓴다(불꽃 잔해는 가산, 빗줄기 꼬리는 반투명) —
            // 그래서 렌더러가 그룹마다 하나씩 필요하다.
            var built: [(key: String, renderer: ParticleRenderer, ratio: Float)] = []
            Self.buildParticleRenderers(
                preset: preset, texturePath: texturePath, blend: blend,
                normalPath: normalPath, refractAmount: refractAmount, key: "0",
                instances: 1, layer: layer, compositor: context.compositor, resolver: context.resolver,
                into: &built, skipped: &skipped)
            guard let root = built.first, root.key == "0" else {
                skipped.append("\(layer.name): 파티클 렌더러를 만들지 못했다: \(texturePath)")
                return
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
                layerList.append((quad, .particles(entry.renderer)))
            }
            // 레이어 원점을 함께 들고 있는다. 커서를 이 시스템의 좌표계로
            // 옮기려면 필요하다 — 파티클 좌표는 레이어 기준 상대 좌표다.
            particles.append((system, groups,
                              SIMD2(Float(layer.origin.x), Float(layer.origin.y))))

        case .sound(let sound):
            // 그리지 않는다. 소리만 준비해 둔다.
            guard let player = Self.makePlayer(sound, resolver: context.resolver) else {
                skipped.append(
                    "\(layer.name): 재생할 수 없는 소리 형식이다 "
                        + "(\(sound.paths.map { ($0 as NSString).pathExtension }.joined(separator: ", ")))")
                return
            }
            // startsilent인 소리는 스크립트가 켜기 전까지 나지 않는다.
            // 스크립트를 아직 돌리지 않으므로 준비만 하고 재생 목록에는 넣지 않는다.
            // 씬이 정한 볼륨을 따로 들고 있어야 사용자 설정을 곱할 수 있다.
            // AVAudioPlayer는 원래 값을 기억하지 않는다. startsilent인 소리는
            // 스크립트가 `play()`를 부르기 전까지 준비만 해 둔다.
            sounds.append(SoundEntry(player: player, sceneVolume: Float(sound.volume),
                                     wanted: !sound.startsSilent))

        case .text(let text):
            // 폰트가 없어도 그린다 — 시스템 폰트로 대체된다. 글자가 아예
            // 안 나오는 것보다 다른 폰트로라도 나오는 게 낫다.
            let fontData = text.usesSystemFont ? nil : context.resolver.data(for: text.fontPath)
            if fontData == nil && !text.usesSystemFont {
                degraded.append("\(layer.name): 폰트를 찾을 수 없어 시스템 폰트로 그린다: \(text.fontPath)")
            }
            // 오브젝트의 size는 글자 크기가 아니라 **상자**다. 실물에서 411x5300짜리도
            // 있어서 그대로 점 크기로 쓰면 글자가 화면 밖으로 밀려난다. 대신 고정
            // 크기로 굽고 상자에 맞춰 줄인다. 256은 레티나에서 흐리지 않을 만큼 크다.
            let pointSize = 256.0
            // 글자 스크립트는 씬 호스트가 돌린다. 저장된 글자로 먼저 굽고,
            // 첫 틱의 결과가 오면 바꾼다.
            let state = TextState(
                text: text, fontData: fontData, pointSize: pointSize,
                origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                box: SIMD2(Float(layer.size.x), Float(layer.size.y)),
                worldOrigin: layer.origin, worldAngles: layer.angles)
            texts.append(state)
            rasterize(state, compositor: context.compositor)
            state.layerIndex = layerList.count
            // 글자 색은 래스터화할 때 이미 칠했다. 여기서 또 곱하면 색이 제곱된다.
            // 틴트는 흰색으로 두고 레이어 투명도만 넘긴다.
            //
            // 밝기는 색과 별개라 여기서 곱한다. **실물에서 섞기가 걸린
            // 레이어 여덟 중 여섯이 글자다**(시계·요일·날짜) — 이미지 쪽만
            // 이어 두면 정작 필요한 곳에 안 걸린다.
            let textBrightness = Float(layer.brightness)
            var textQuad = QuadInstance(
                origin: state.origin, size: state.size,
                color: SIMD4(textBrightness, textBrightness, textBrightness,
                             layer.visible ? Float(layer.alpha) : 0),
                rotation: Float(layer.rotation),
                parallaxDepth: Float(layer.parallaxDepth),
                blendMode: Int32(layer.colorBlendMode))
            if context.isPerspective {
                // 원근 씬의 글자는 세계에 놓인 판이다. 구운 크기가 이미 씬 단위다.
                textQuad.world = Scene3D.world(
                    origin: layer.origin, anglesDegrees: layer.angles,
                    scale: Vec3(x: 1, y: 1, z: 1),
                    size: Vec2(x: Double(state.size.x), y: Double(state.size.y)))
            }
            layerList.append((textQuad, .dynamic { [weak state] in state?.texture }))

        case .shadedImage(let materialPath, _):
            // 재질의 셰이더가 그림을 만든다. 메시 렌더러에 단위 사각형을 준다 —
            // 셰이더 컴파일·유니폼·텍스처가 메시와 똑같기 때문이다.
            guard context.isPerspective else {
                skipped.append("\(layer.name): 직교 씬의 셰이더 이미지는 아직 그리지 않는다: \(materialPath)")
                return
            }
            do {
                let renderer = try ModelRenderer(
                    device: context.compositor.device, model: MDLModel.unitQuad(),
                    materialPath: materialPath, resolver: context.resolver, includes: context.shaderIncludes,
                    makeTexture: { try context.compositor.makeTexture(from: $0) },
                    sampler: context.compositor.sharedSampler,
                    eye: { [weak context = context.compositor] in context?.cameraEye ?? .zero },
                        clearColor: context.clearColor, ambient: context.ambient, skylight: context.skylight)
                // 판의 크기는 size × scale 세계 단위다(실물 배경 구름 64 × 10).
                quad.world = Scene3D.world(
                    origin: layer.origin,
                    anglesDegrees: Vec3(x: layer.angles.x, y: layer.angles.y, z: layer.rotation * 180 / .pi),
                    scale: Vec3(x: 1, y: 1, z: 1),
                    size: Vec2(x: layer.size.x, y: layer.size.y))
                layerList.append((quad, .model(renderer)))
            } catch {
                skipped.append("\(layer.name): 셰이더 이미지를 그리지 못한다: \(error)")
            }

        case .model(let path, let skin):
            guard context.isPerspective else {
                skipped.append("\(layer.name): 직교 씬의 3D 메시는 아직 그리지 않는다: \(path)")
                return
            }
            guard let raw = context.resolver.data(for: path) else {
                skipped.append("\(layer.name): 메시를 찾을 수 없다: \(path)")
                return
            }
            do {
                let model = try MDLModel.parse(raw)
                // `skin`은 메시의 재질 목록 번호다. 벗어나면 첫 재질로 간다.
                guard !model.materials.isEmpty else {
                    skipped.append("\(layer.name): 메시에 재질이 없다: \(path)")
                    return
                }
                let materialPath = model.materials[min(skin, model.materials.count - 1)]
                let renderer = try ModelRenderer(
                    device: context.compositor.device, model: model, materialPath: materialPath,
                    resolver: context.resolver, includes: context.shaderIncludes,
                    makeTexture: { try context.compositor.makeTexture(from: $0) },
                    sampler: context.compositor.sharedSampler,
                    eye: { [weak context = context.compositor] in context?.cameraEye ?? .zero },
                        clearColor: context.clearColor, ambient: context.ambient, skylight: context.skylight)
                quad.world = Scene3D.world(
                    origin: layer.origin,
                    anglesDegrees: Vec3(x: layer.angles.x, y: layer.angles.y, z: layer.rotation * 180 / .pi),
                    scale: layer.scale)
                layerList.append((quad, .model(renderer)))
            } catch {
                skipped.append("\(layer.name): 3D 메시를 그리지 못한다: \(error)")
            }

        case .unsupported(let reason):
            skipped.append("\(layer.name): \(reason)")
        }
    
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
        // 사용자가 설정 창에서 바꾼 값을 얹는다. 씬을 읽을 때 한 번 얹히므로
        // 값이 바뀌면 배경화면을 다시 연다.
        // 프리셋이 정한 값 위에 사용자가 바꾼 값을 얹는다. 텍스처 속성은 파일 경로다.
        let overrides = Self.userPropertyValues(for: item)
        var userTextures: [String: String] = [:]
        if let data = try? Data(contentsOf: item.directory.appendingPathComponent("project.json")) {
            for property in UserProperty.load(projectJSON: data) {
                guard case .texture = property.kind,
                      case .text(let path)? = overrides[property.name], !path.isEmpty else { continue }
                userTextures[property.name] = path
            }
        }
        let document = try SceneDocument.load(
            from: reader, assets: assets, userOverrides: overrides, userTextures: userTextures)

        let compositor = try MetalCompositor(device: device)
        compositor.setProjection(width: document.orthoWidth, height: document.orthoHeight)
        // 첫 draw 전에도 커서 계산 등이 drawable 크기를 물어볼 수 있어 미리 준다.
        // draw(in:)이 매 프레임 다시 재므로 창 크기가 달라져도 스스로 맞는다.
        compositor.setDrawableSize(view.drawableSize)
        compositor.setZoom(document.zoom)
        // 배경화면마다 저장해 둔 화면 맞춤 방식(없으면 기본값 채우기).
        compositor.setCanvasFit(CanvasFitPreferencesStore.mode(for: item.id))
        parallaxAmount = document.parallaxAmount
        ortho = SIMD2(Float(document.orthoWidth), Float(document.orthoHeight))
        camera = document.camera
        if document.clearEnabled {
            compositor.setClearColor(MTLClearColor(
                red: document.clearColor.x, green: document.clearColor.y,
                blue: document.clearColor.z, alpha: 1
            ))
        }

        // 바깥 파일은 이 배경화면과 프리셋의 폴더 안에서만 읽는다.
        let resolver = ReferenceResolver(
            pkg: reader, assets: assets,
            externalRoots: [item.directory] + (item.presetDirectory.map { [$0] } ?? []))
        // 셰이더가 `#include "common.h"` 하는 헤더들. pkg와 assets 양쪽에 있다.
        // 안 모으면 `ApplyBlending` 같은 공용 함수를 못 찾아 컴파일이 통째로 실패한다.
        let shaderIncludes = Self.collectShaderHeaders(reader: reader, assets: assets)

        let context = BuildContext(
            device: device, compositor: compositor, resolver: resolver,
            shaderIncludes: shaderIncludes, isPerspective: document.isPerspective,
            canvas: Vec2(x: Double(document.orthoWidth), y: Double(document.orthoHeight)),
            clearColor: document.clearEnabled
                ? SIMD4(Float(document.clearColor.x), Float(document.clearColor.y),
                        Float(document.clearColor.z), 1)
                : SIMD4(0, 0, 0, 1),
            ambient: SIMD3(Float(document.ambientColor.x), Float(document.ambientColor.y),
                           Float(document.ambientColor.z)),
            skylight: SIMD3(Float(document.skylightColor.x), Float(document.skylightColor.y),
                            Float(document.skylightColor.z)))
        buildContext = context
        layerList = []
        // layerList의 인덱스를 들고 있다 — layerList와 같이 끊어야 다음 씬을
        // 열 때 엉뚱한 레이어의 UV를 덮어쓰지 않는다.
        spriteSheetImages = []
        puppets = []
        puppetStartTime = nil
        effectChains = []
        compositionLayers = [:]
        postLayers = []
        scriptTargets = [:]
        appliedStates = [:]
        unspawnable = []
        reportedFailures = []
        // 스크립트가 화면·캔버스 크기를 물어본다(실물에서 `engine.screenResolution` 13회).
        // 없으면 참조 오류로 스크립트가 통째로 죽는다.
        let screen = view.window?.screen ?? NSScreen.main
        let scriptEnvironment = SceneScriptRuntime.Environment(
            screenWidth: Double(screen?.frame.width ?? CGFloat(document.orthoWidth)),
            screenHeight: Double(screen?.frame.height ?? CGFloat(document.orthoHeight)),
            canvasWidth: Double(document.orthoWidth),
            canvasHeight: Double(document.orthoHeight))

        // 숨은 레이어도 스크립트가 있으면 세운다 — 스크립트가 나중에 보이게 할 수 있고,
        // 실물 원근 씬은 카메라·프리즘 로직을 숨은 레이어에 둔다. 알파 0으로 시작한다.
        for layer in document.layers where layer.visible || !layer.scripts.isEmpty {
            addLayer(layer, context: context)
        }

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

        reportedSkipped = skipped.count
        reportedDegraded = degraded.count
        guard !layerList.isEmpty else {
            // Metal 자체가 없는 경우(unsupportedType)와는 원인이 다르다 — 여기 도달했다는
            // 것 자체가 device가 있었다는 뜻이다. DisplayManager.attach는 어떤 오류든
            // 잡아 preview로 폴백하므로(WallflowApp/DisplayManager.swift 참고) 동작은
            // 바뀌지 않지만, 로그와 향후 분기를 위해 원인을 구분해 던진다.
            throw RendererError.noDrawableLayers
        }

        if !effectChains.isEmpty {
            let bytes = effectChains.reduce(0) { $0 + $1.chain.textureBytes }
            FileHandle.standardError.write(Data(
                ("이펙트 체인 \(effectChains.count)개, "
                    + "패스 \(effectChains.reduce(0) { $0 + $1.chain.passCount })개, "
                    + "텍스처 \(bytes / 1_000_000)MB\n").utf8))
        }
        self.effectStartTime = nil
        self.postEffects = nil
        self.compositionChains = [:]
        self.compositionResolver = resolver
        self.compositionIncludes = shaderIncludes
        if !compositionLayers.isEmpty {
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
        compositor.setLayers(layerList)
        self.compositor = compositor

        // 씬의 스크립트를 한 컨텍스트에 올린다. **숨은 레이어도** 넣는다 — 실물
        // 원근 씬의 카메라·프리즘 로직이 거기 산다. 첫 틱은 여기서 바로 돌려
        // 첫 프레임부터 스크립트가 정한 자리에 그린다.
        parentOf = [:]
        for layer in document.layers {
            if let parent = layer.parentID, parent != layer.id { parentOf[layer.id] = parent }
        }
        let seeds = document.layers.map { layer -> SceneScriptHost.LayerSeed in
            var seed = SceneScriptHost.LayerSeed(layer)
            seed.materialScripts = materialScripts(of: layer.id)
            return seed
        }
        if seeds.contains(where: { !$0.scripts.isEmpty || !$0.materialScripts.isEmpty }) {
            let host = SceneScriptHost(
                layers: seeds,
                camera: document.camera, environment: scriptEnvironment,
                modules: document.scriptModules,
                userProperties: Self.userPropertyValues(for: item))
            if let fatal = host.fatalFailure {
                // 진단 목록은 이미 찍혔다. 여기서 바로 알린다 — 조용히 묻히면
                // 씬이 왜 안 움직이는지 알 길이 없다.
                FileHandle.standardError.write(Data(
                    "씬 \(item.title)의 스크립트를 돌리지 못한다: \(fatal)\n".utf8))
            } else {
                scriptHost = host
                lastScriptTick = CACurrentMediaTime()
                FileHandle.standardError.write(Data(
                    "씬 \(item.title)의 스크립트 \(host.unitCount)개를 올렸다\n".utf8))
                apply(host.tick(frametime: 0))
            }
        }

        // 비디오·파티클·텍스트는 모두 시간에 따라 바뀐다. 시간을 쓰는
        // 이펙트(`g_Time`)·스크립트·퍼펫도 마찬가지다 — 빠지면 빛줄기 같은
        // 이펙트 전용 씬이 첫 프레임에 멈춘 채로 남는다. 붙일 때와
        // apply(.playing)이 needsContinuousDrawing 하나를 같이 써야 한다 —
        // 갈라지면 가려짐으로 멈췄다가 재개될 때만 멈춘 채로 남는 씬이 생긴다.
        if needsContinuousDrawing {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            // 전력 정책이 30fps를 지시한다. 60fps 소스라도 그 이상 그리지 않는다.
            view.preferredFramesPerSecond = PowerPolicy.normalFPS
        }

        view.needsDisplay = true
        // 뷰의 재생 상태가 정해진 뒤에 소리를 맞춘다. 먼저 부르면 아직 정지
        // 상태로 보여 아무것도 재생되지 않는다.
        applySoundSetting()
        updateAudioNeed()
    }

    /// 이 씬을 매 프레임 다시 그려야 하는지. 붙일 때와 재생을 다시 시작할
    /// 때(`apply(.playing)`) 둘 다 이 속성 하나를 쓴다 — 따로 판단하면
    /// 이펙트·스크립트·퍼펫만 움직이는 씬이 한쪽에서 빠져, 가려짐으로
    /// 멈췄다가 재개돼도 검은 화면으로 남는다.
    private var needsContinuousDrawing: Bool {
        PowerPolicy.needsContinuousDrawing(
            hasVideo: !videos.isEmpty, hasParticles: !particles.isEmpty,
            hasText: !texts.isEmpty,
            hasAnimatedEffect: effectChains.contains { $0.chain.isAnimated },
            hasScriptHost: scriptHost != nil, hasPuppets: !puppets.isEmpty,
            hasAnimatedImage: !spriteSheetImages.isEmpty)
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
            // 붙일 때와 같은 needsContinuousDrawing을 쓴다 — 예전에는 여기서
            // 비디오·파티클·텍스트만 봐서, 이펙트·스크립트·퍼펫만으로 움직이는
            // 씬이 가려짐으로 멈췄다가 재개돼도 검은 화면으로 남았다.
            if needsContinuousDrawing {
                view?.isPaused = false
                view?.preferredFramesPerSecond = fps
            }
            view?.needsDisplay = true
        }
    }

    func stop() {
        for video in videos { video.stop() }
        videos.removeAll()
        for entry in sounds { entry.player.stop() }
        sounds.removeAll()
        particles.removeAll()
        spriteSheetImages.removeAll()
        texts.removeAll()
        puppets.removeAll()
        puppetStartTime = nil
        lastFrameTime = nil
        lastScriptTick = nil
        scriptHost = nil
        scriptInFlight = false
        scriptTargets = [:]
        appliedStates = [:]
        buildContext = nil
        compositor = nil
        layerList = []
        effectChains = []
        effectStartTime = nil
        postEffects = nil
        postEffectSource = nil
        compositionLayers = [:]
        compositionChains = [:]
        // 이 씬이 더는 소리를 필요로 하지 않는다. 아무도 안 쓰면 캡처가 꺼진다.
        setAudioNeed(false)
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 다음 draw(in:)도 스스로 갱신하지만, 이 프레임 안에서 draw보다 먼저
        // sceneCursorPosition(tickScripts)이 돌 수 있어 미리 갱신해 둔다 —
        // 안 그러면 리사이즈 프레임에서 커서가 지난 프레임의 크기를 기준으로 잡힌다.
        compositor?.setDrawableSize(size)
        view.needsDisplay = true
    }

    private func recordFrame() {
        let now = CACurrentMediaTime()
        if let last = lastDrawTime { frameIntervals.append(now - last) }
        lastDrawTime = now
        guard frameIntervals.count >= 150 else { return }
        let sorted = frameIntervals.sorted()
        let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
        let line = "FRAMEDBG n=\(sorted.count) 중앙값 \(ms(sorted[sorted.count / 2]))ms "
            + "p95 \(ms(sorted[Int(Double(sorted.count) * 0.95)]))ms 최대 \(ms(sorted.last ?? 0))ms "
            + "fps상한 \(view?.preferredFramesPerSecond ?? 0)\n"
        FileHandle.standardError.write(Data(line.utf8))
        frameIntervals.removeAll(keepingCapacity: true)
    }

    func draw(in view: MTKView) {
        if Self.frameDebug { recordFrame() }
        updateParallax(in: view)
        updateCamera(in: view)
        tickScripts(in: view)
        if !puppets.isEmpty {
            let now = CACurrentMediaTime()
            let start = puppetStartTime ?? now
            puppetStartTime = start
            for puppet in puppets { puppet.update(time: now - start) }
        }
        // 파티클과 스프라이트 시트 이미지가 dt를 함께 쓴다 — 같은 프레임이면
        // 같은 dt여야 한다. 첫 프레임(또는 막 재생을 재개한 프레임)은 직전 시각이
        // 없다. 0을 넘기면 그만큼 멈춰 있던 시간이 한 번에 적분되지 않는다
        // (`apply(.paused)`가 lastFrameTime을 nil로 끊어 둔다).
        let dt: CFTimeInterval
        if !particles.isEmpty || !spriteSheetImages.isEmpty {
            let now = CACurrentMediaTime()
            dt = lastFrameTime.map { now - $0 } ?? 0
            lastFrameTime = now
        } else {
            dt = 0
        }
        if !particles.isEmpty {
            // 커서를 씬 좌표로 옮긴다. 제어점이 마우스를 따라가는 프리셋이
            // 이걸 본다 — 반딧불이 손끝을 피해 흩어지는 것이 그것이다.
            let cursor = sceneCursorPosition(in: view)
            for entry in particles {
                if let cursor {
                    entry.system.cursorPosition = Vec3(
                        x: Double(cursor.x - entry.layerOrigin.x),
                        y: Double(cursor.y - entry.layerOrigin.y),
                        z: 0)
                }
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
        if !spriteSheetImages.isEmpty, let compositor {
            // elapsed는 dt만 쌓는다 — 멈췄다 다시 그릴 때 dt가 0이 되므로(위 참고)
            // 여기서 따로 시각을 손보지 않아도 건너뛴 시간만큼 튀지 않는다.
            var changed = false
            for i in spriteSheetImages.indices {
                // 스크립트가 pause()했으면(실물 미디어 버튼) 시간을 안 쌓는다 — 안
                // 막으면 못박아 둔 칸이 매 프레임 다시 넘어가 자동 재생처럼 보인다.
                // 나중에 play()하면 여기서 멈췄던 elapsed부터 그대로 이어진다.
                if spriteSheetImages[i].scriptPlaying { spriteSheetImages[i].elapsed += dt }
                let entry = spriteSheetImages[i]
                guard entry.layerIndex < layerList.count,
                      let frame = entry.sheet.frame(atElapsed: entry.elapsed),
                      frame != entry.lastFrame
                else { continue }
                spriteSheetImages[i].lastFrame = frame
                layerList[entry.layerIndex].0.uvOrigin = SIMD2(
                    Float(frame.x) / entry.textureSize.x, Float(frame.y) / entry.textureSize.y)
                layerList[entry.layerIndex].0.uvScale = SIMD2(
                    Float(frame.width) / entry.textureSize.x, Float(frame.height) / entry.textureSize.y)
                changed = true
            }
            if changed { compositor.setLayers(layerList) }
        }
        compositor?.draw(in: view)
    }
}
