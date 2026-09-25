import AppKit
import WebKit
import WallflowKit

/// HTML/JS 배경화면을 WKWebView로 렌더한다.
///
/// 정지는 페이지를 언로드하지 않는다(상태를 잃지 않기 위해). 대신 두 가지를 함께 한다:
/// 1) document.getAnimations()로 문서의 모든 애니메이션(자식 엘리먼트 것 포함)을 멈추고,
/// 2) 뷰를 isHidden=true로 감춘다. 비가시 뷰가 되면 WebKit이 그리기를 멈추고
///    requestAnimationFrame 콜백도 더 이상 호출하지 않는다.
///
/// 이 클래스는 rAF를 직접 후킹하지 않는다. rAF가 멎는 것은 isHidden의 결과다.
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer {
    private let item: WallpaperItem
    private var webView: WKWebView?
    /// ~30Hz로 `wallpaperRegisterAudioListener` 콜백에 스펙트럼을 밀어 넣는다.
    /// 감춰진 동안은 멎는다 — 애니메이션과 같은 이유다(뷰가 안 그리는데 계속
    /// evaluateJavaScript를 부를 이유가 없다).
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

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    func makeView() -> NSView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

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
                guard let self, let webView = self.webView, !webView.isHidden else { return }
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
            // 감추기 전에 JS를 먼저 보낸다. 순서가 바뀌면 비가시 뷰에서
            // 평가가 지연될 수 있다.
            webView?.evaluateJavaScript(Self.pauseAnimationsJS)
            webView?.isHidden = true
        case .playing:
            webView?.isHidden = false
            webView?.evaluateJavaScript(Self.resumeAnimationsJS)
        }
    }

    func stop() {
        audioTimer?.invalidate()
        audioTimer = nil
        webView?.stopLoading()
        // 델리게이트를 먼저 떼어낸다 — 안 떼면 이 빈 페이지의 didFinish가 다시
        // 걸려 applyUserProperties를 빈 문서에 헛되이 부르고 오디오 타이머를
        // 되살린다.
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
    }
}

extension WebRenderer: WKNavigationDelegate {}
