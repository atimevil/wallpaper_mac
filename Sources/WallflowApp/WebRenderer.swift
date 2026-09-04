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
final class WebRenderer: WallpaperRenderer {
    private let item: WallpaperItem
    private var webView: WKWebView?

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

        let view = WKWebView(frame: .zero, configuration: config)
        // drawsBackground는 비공개 프로퍼티라 쓰지 않는다.
        // 배경 윈도우가 이미 불투명 검정이므로 이것으로 충분하다.
        view.underPageBackgroundColor = .black
        view.autoresizingMask = [.width, .height]
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
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
    }
}
