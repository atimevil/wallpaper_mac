import AppKit
import WebKit
import WallflowKit

/// HTML/JS 배경화면을 WKWebView로 렌더한다.
///
/// 정지는 페이지를 언로드하지 않는다(상태를 잃지 않기 위해).
/// document.getAnimations()로 문서의 모든 애니메이션(자식 엘리먼트 것 포함)을 멈춘다.
///
/// **뷰는 절대 isHidden으로 감추지 않는다** — `SceneRenderer.apply(_:)`와 같은 이유다
/// ("뷰를 숨기지 않는다. 마지막 프레임이 남아야 검은 화면이 되지 않는다"). 실물 앱에서
/// 확인한 결정적 이유: `AppCoordinator`는 `power.start()`(가려짐 여부를 한 번 즉시
/// poll한다)를 `restoreLastSelection()`(첫 배경화면을 붙인다)보다 **먼저** 부른다.
/// 갓 만든 윈도우는 그 순간 `occlusionState`가 아직 `.visible`을 안 담고 있는 게
/// 보통이라, 이 첫 poll은 거의 항상 `.paused`로 판정하고 `DisplayManager.lastDirective`에
/// 그게 그대로 박힌다. 그러니 **모든 웹 배경화면은 붙자마자 `apply(.paused)`를 먼저
/// 받는다** — 뷰를 숨기면 첫 프레임을 그리기도 전에 감춰져, 다음 poll(최대 5초 뒤,
/// 이 컴퓨터가 바쁘면 더 늦게)이 되돌려 놓을 때까지 검은 창 배경(`WallpaperWindow`의
/// `backgroundColor = .black`)만 보인다 — 실물 3개(1081733658/1748506393/893418273)가
/// 정확히 이 경로로 흰/검은 화면이었다(로그의 첫 줄이 "가려져 멈춘다", 마지막 줄이
/// "재개한다"인 이유).
///
/// 그 대가로, 가려진 동안 canvas/WebGL을 requestAnimationFrame으로 계속 그리는
/// 페이지는 CSS 애니메이션과 달리 못 멈춘다(getAnimations()는 CSS만 본다).
/// ponytail: rAF까지 가려짐에 맞춰 멈추려면 document-start에 rAF를 감싸는 스크립트가
/// 더 필요하다 — 지금은 "검은 화면 없음"이 "가려진 동안 CPU 약간 더 씀"보다 우선이라
/// 뒤로 미룬다.
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer {
    private let item: WallpaperItem
    private var webView: WKWebView?
    /// 지금 정지 상태인지. 오디오 디스패치를 건너뛰는 데만 쓴다 — 뷰 자체는
    /// 가려짐과 상관없이 계속 보인다(위 클래스 설명 참고).
    private var isPaused = false
    /// ~30Hz로 `wallpaperRegisterAudioListener` 콜백에 스펙트럼을 밀어 넣는다.
    /// 정지 동안은 멎는다 — 어차피 페이지가 애니메이션을 멈춰 뒀으니 계속
    /// evaluateJavaScript를 부를 이유가 없다.
    private var audioTimer: Timer?

    /// 페이지가 만드는 모든 video/audio 엘리먼트를 강제로 음소거한다.
    /// 새로 추가되는 엘리먼트까지 잡기 위해 MutationObserver를 쓴다.
    /// mediaTypesRequiringUserActionForPlayback 설정과 함께 이중 방어선을 이룬다.
    private static let forceMuteJS = """
    (function() {
        function mute(el) {
            try { el.muted = true; el.volume = 0; } catch (e) {}
        }
        function muteAll(root) {
            if (!root || !root.querySelectorAll) { return; }
            root.querySelectorAll('video, audio').forEach(mute);
        }
        muteAll(document);
        document.addEventListener('DOMContentLoaded', function () { muteAll(document); });
        try {
            new MutationObserver(function (mutations) {
                mutations.forEach(function (m) {
                    m.addedNodes.forEach(function (node) {
                        if (node.nodeType !== 1) { return; }
                        if (node.matches && node.matches('video, audio')) { mute(node); }
                        muteAll(node);
                    });
                });
            }).observe(document.documentElement || document, { childList: true, subtree: true });
        } catch (e) {}
    })();
    """

    /// 문서의 모든 애니메이션(자식 엘리먼트의 CSS 애니메이션 포함)을 멈춘다.
    /// body에 animationPlayState를 거는 방식은 상속되지 않아 자식이 계속 돌기 때문에
    /// getAnimations()를 쓴다. getAnimations()가 없는 환경에서는 조용히 아무것도 하지 않는다.
    ///
    /// 우리가 멈춘 것만 __wallflowPaused에 기록해서, 재생 시 페이지가 스스로
    /// 멈춰둔 애니메이션까지 되살리지 않게 한다.
    private static let pauseAnimationsJS = """
    (function() {
        if (typeof document.getAnimations !== 'function') { return; }
        try {
            if (!window.__wallflowPaused) { window.__wallflowPaused = new WeakSet(); }
        } catch (e) { window.__wallflowPaused = null; }
        try {
            document.getAnimations().forEach(function (a) {
                try {
                    if (a.playState !== 'running') { return; }
                    a.pause();
                    if (window.__wallflowPaused) { window.__wallflowPaused.add(a); }
                } catch (e) {}
            });
        } catch (e) {}
    })();
    """

    /// pauseAnimationsJS가 멈춘 애니메이션만 다시 재생한다.
    /// 기록이 없으면(WeakSet을 못 만든 환경) 전부 재생해서 화면이 멈춘 채로
    /// 남는 최악의 경우는 피한다.
    private static let resumeAnimationsJS = """
    (function() {
        if (typeof document.getAnimations !== 'function') { return; }
        var tracked = window.__wallflowPaused;
        try {
            document.getAnimations().forEach(function (a) {
                try {
                    if (tracked && !tracked.has(a)) { return; }
                    a.play();
                    if (tracked) { tracked.delete(a); }
                } catch (e) {}
            });
        } catch (e) {}
    })();
    """

    /// `WALLFLOW_WEB_DEBUG`가 있으면 페이지의 console.log/warn/error와
    /// window.onerror를 앱 stderr로 그대로 흘린다. 로그가 비어 있던 실물
    /// 3개(1081733658/1748506393/893418273)를 실사용 창(WallpaperWindow, 데스크톱
    /// 레벨) 안에서 진단하는 데 썼다 — 헤드리스 하네스에서는 안 보이던 문제가
    /// 실제 창에서만 나서, 그 창 안의 콘솔을 직접 봐야 했다.
    private static let webDebug = ProcessInfo.processInfo.environment["WALLFLOW_WEB_DEBUG"] != nil
    private static let consoleMessageName = "wallflowConsole"
    private static let consoleHookJS = """
    (function() {
        function send(level, args) {
            try {
                var parts = Array.prototype.slice.call(args).map(function (a) {
                    try { return typeof a === 'string' ? a : JSON.stringify(a); }
                    catch (e) { return String(a); }
                });
                window.webkit.messageHandlers.\(consoleMessageName).postMessage(
                    level + ': ' + parts.join(' '));
            } catch (e) {}
        }
        ['log', 'warn', 'error'].forEach(function (level) {
            var orig = console[level];
            console[level] = function () {
                send(level, arguments);
                if (orig) { orig.apply(console, arguments); }
            };
        });
        window.addEventListener('error', function (e) {
            send('onerror', [e.message, e.filename, e.lineno, e.colno,
                (e.error && e.error.stack) || '']);
        });
        window.addEventListener('unhandledrejection', function (e) {
            send('onunhandledrejection', [String(e.reason)]);
        });
    })();
    """

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    func makeView() -> NSView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // file://로 연 문서와 그게 불러오는 다른 file:// 리소스(같은 폴더의
        // script.js, 텍스처 이미지 등)를 WebKit은 기본적으로 서로 다른 출처로
        // 본다. 그러면 이미지를 WebGL 텍스처로 쓰려는 시도가 보안 예외로 막혀
        // 스크립트가 그 자리에서 죽는다 — 실물 1748506393이 이 경로였다:
        // LDR_RGB1_0.png를 텍스처로 로드하다 죽어서 update() 렌더 루프
        // 진입 자체가 안 됐다(로그의 "Script error."가 그 흔적 — 이 키를
        // 켜면 사라진다. WKWebView는 예외 message를 그대로 안 주고 출처가
        // 갈리면 "Script error."로 뭉갠다). 비공개 키지만, file:// 콘텐츠를
        // 여는 앱들이 널리 쓰는 표준적인 우회다 — allowingReadAccessTo로 이미
        // 그 폴더 전체를 읽게 해 준 것과 같은 취지, 출처 판정만 맞춘다.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // 배경화면은 소리를 내면 안 된다. 오디오가 있는 미디어는 사용자 제스처
        // 없이 재생될 수 없게 막는다. 음소거된 비디오는 오디오가 없는 것으로
        // 취급되어 자동재생/애니메이션이 계속된다 (muted 비디오 배경화면은
        // 여전히 정상 동작해야 한다).
        config.mediaTypesRequiringUserActionForPlayback = .audio

        // 위 설정을 우회하는 페이지가 있을 수 있으니, JS로도 모든
        // video/audio 엘리먼트를 강제 음소거한다 (이중 방어).
        let muteScript = WKUserScript(
            source: Self.forceMuteJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(muteScript)

        // WE 스펙 JS API(wallpaperRegisterAudioListener 등)를 페이지 자신의
        // 스크립트보다 먼저 만들어 둔다. 없으면 실물 페이지 일부가 그 자리에서
        // 예외를 내고 멎는다(893418273: window.onload 안에서 조건 없이 호출).
        let bridgeScript = WKUserScript(
            source: WebEngineBridge.bootstrapJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(bridgeScript)
        // 페이지가 wallpaperRegisterAudioListener를 실제로 부르면(등록해 두고 안
        // 쓰는 페이지도 있을 수 있어 "정의돼 있다"가 아니라 "불렀다"를 본다)
        // 이 메시지가 온다 — 그때만 소리가 필요한 렌더러로 등록한다.
        config.userContentController.add(self, name: WebEngineBridge.audioNeededMessageName)

        if Self.webDebug {
            config.userContentController.add(self, name: Self.consoleMessageName)
            config.userContentController.addUserScript(WKUserScript(
                source: Self.consoleHookJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
            // 페이지 자신의 스크립트가 돌기 전(atDocumentStart) 뷰포트 크기를 찍는다.
            // 일부 페이지(1748506393)는 로드 시점의 canvas.clientWidth로 프레임버퍼를
            // 만들고, 매 프레임 resizeCanvas()가 그 값이 바뀌면 프레임버퍼를 통째로
            // 새로 만든다 — 로드 시점 크기가 최종 창 크기와 다르면 초기 스플랫이
            // 사라진다.
            config.userContentController.addUserScript(WKUserScript(
                source: """
                (function() {
                    window.webkit.messageHandlers.\(Self.consoleMessageName).postMessage(
                        'earlyViewport: ' + window.innerWidth + 'x' + window.innerHeight);
                })();
                """,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        let view = WKWebView(frame: .zero, configuration: config)
        // drawsBackground는 비공개 프로퍼티라 쓰지 않는다.
        // 배경 윈도우가 이미 불투명 검정이므로 이것으로 충분하다.
        view.underPageBackgroundColor = .black
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        webView = view
        return view
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: item.contentURL.path) else {
            throw RendererError.contentMissing(item.contentURL)
        }
        // 배경화면 폴더 전체를 읽기 허용해야 상대 경로 리소스가 로드된다.
        webView?.loadFileURL(item.contentURL, allowingReadAccessTo: item.directory)
    }

    /// 페이지가 다 뜨면(자기 손으로 wallpaperPropertyListener를 만든 뒤) 실물 WE처럼
    /// project.json 기본값 + 사용자 조정값을 **한 번** 먹인다. 이게 없으면 스크립트가
    /// 자기 설정을 초기화하지 않아 캔버스가 비어 있다 — 실물 3개가 이 경로로 죽어 있었다.
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let values = SceneRenderer.userPropertyValues(for: item)
            webView.evaluateJavaScript(WebEngineBridge.applyPropertiesJS(values))
            startAudioTimer()
            if Self.webDebug {
                // 뜨자마자는 아직 그릴 시간이 없다. 2초 뒤 실제로 뭐가
                // 그려졌는지(캔버스 크기·픽셀 유무·WebGL 상태) 한 번 찍는다.
                let debugItemID = item.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
                    webView?.evaluateJavaScript(WebEngineBridge.debugDiagnosticsJS) { result, error in
                        FileHandle.standardError.write(Data(
                            "[web \(debugItemID)] +2s diag=\(result ?? "nil") err=\(String(describing: error))\n"
                                .utf8))
                    }
                }
            }
        }
    }

    /// 오디오 스펙트럼을 30Hz로 페이지에 밀어 넣는다. 듣고 있는 소리가 없으면
    /// (아무도 캡처를 안 켰으면) 0으로 채워진 배열이 나가 비주얼라이저는 잠잠하게
    /// 그려진다 — 빈 콜백보다 낫다(콜백 자체가 없다고 여겨 대기 화면에 머무는
    /// 페이지가 있었다, 893418273).
    private func startAudioTimer() {
        guard audioTimer == nil else { return }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let webView = self.webView, !self.isPaused else { return }
                let silence = [Float](repeating: 0, count: 64)
                let bands = SceneRenderer.audioBands[64] ?? (left: silence, right: silence)
                webView.evaluateJavaScript(
                    WebEngineBridge.dispatchAudioJS(left: bands.left, right: bands.right))
            }
        }
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            isPaused = true
            webView?.evaluateJavaScript(Self.pauseAnimationsJS)
        case .playing:
            isPaused = false
            webView?.evaluateJavaScript(Self.resumeAnimationsJS)
        }
    }

    func stop() {
        audioTimer?.invalidate()
        audioTimer = nil
        // 씬 렌더러들과 같은 창구에서 등록을 뗀다 — 이 웹 배경화면이 떨어지면
        // 더는 소리가 필요 없다. 등록한 적이 없어도(오디오 API를 안 쓰는
        // 페이지) 조용히 아무 일도 없다.
        SceneRenderer.setAudioNeeded(false, for: ObjectIdentifier(self))
        // 메시지 핸들러를 안 떼면 userContentController가 self를 계속 들고
        // 있어 순환 참조로 이 렌더러가 절대 해제되지 않는다.
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: WebEngineBridge.audioNeededMessageName)
        if Self.webDebug {
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: Self.consoleMessageName)
        }
        webView?.stopLoading()
        // 델리게이트를 먼저 떼어낸다 — 안 떼면 이 빈 페이지의 didFinish가 다시
        // 걸려 applyUserProperties를 빈 문서에 헛되이 부르고 오디오 타이머를
        // 되살린다.
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
    }
}

extension WebRenderer: WKNavigationDelegate {}

extension WebRenderer: WKScriptMessageHandler {
    /// 페이지가 `wallpaperRegisterAudioListener`를 부르면 온다. `SceneRenderer`가
    /// 쓰는 `audioNeeders` 창구에 이 렌더러의 신원으로 등록한다 — 화면이 여럿이거나
    /// 씬과 웹이 섞여 있어도 하나라도 필요하면(합집합이 비지 않으면) 캡처가 켜지는
    /// 규칙은 그대로다. `AudioSpectrum.isEnabled`(소리 반응 설정) 게이팅은
    /// `AppCoordinator.applyAudioCapture()`가 이미 하고 있어 여기서 다시 안 본다.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            if message.name == WebEngineBridge.audioNeededMessageName {
                SceneRenderer.setAudioNeeded(true, for: ObjectIdentifier(self))
                return
            }
            if message.name == Self.consoleMessageName {
                FileHandle.standardError.write(Data("[web \(item.id)] \(message.body)\n".utf8))
            }
        }
    }
}
