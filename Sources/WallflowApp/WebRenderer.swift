import AppKit
import WebKit
import WallflowKit

/// HTML/JS 배경화면을 WKWebView로 렌더한다.
/// 정지는 페이지를 죽이지 않고 requestAnimationFrame을 멈추는 방식으로 한다.
final class WebRenderer: WallpaperRenderer {
    private let item: WallpaperItem
    private var webView: WKWebView?

    init(item: WallpaperItem) {
        self.item = item
    }

    func makeView() -> NSView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // 배경화면은 소리를 내면 안 된다.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

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
            // 페이지를 언로드하지 않는다. 상태를 잃지 않으면서 그리기만 멈춘다.
            webView?.evaluateJavaScript("document.body && (document.body.style.animationPlayState='paused');")
            webView?.isHidden = true
        case .playing:
            webView?.isHidden = false
            webView?.evaluateJavaScript("document.body && (document.body.style.animationPlayState='running');")
        }
    }

    func stop() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
    }
}
