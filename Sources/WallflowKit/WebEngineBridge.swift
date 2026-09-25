import Foundation

/// 웹 배경화면에 WE의 JS API를 흉내 내 주입하기 위한 순수 조각들.
///
/// 실물 WE 엔진은 페이지가 다 뜬 뒤 `window.wallpaperPropertyListener.applyUserProperties`를
/// project.json 값으로 **한 번** 부른다. 이걸 안 부르면 스크립트가 설정하는 켜기/색/속도
/// 값이 전부 초기화되지 않는다 — 실물 3개(1081733658/1748506393/893418273)가 이 경로로
/// 죽어 있었다. 그중 하나(893418273)는 한술 더 떠 `window.wallpaperRegisterAudioListener`가
/// 아예 없으면 `window.onload` 안에서 예외가 나 `requestAnimationFrame`까지 도달하지
/// 못하고 흰 화면으로 멎는다 — 조건문 없이 바로 부르는 실물 코드로 확인했다.
public enum WebEngineBridge {
    /// 페이지가 실제로 `wallpaperRegisterAudioListener`를 불렀을 때(등록만 해 두고
    /// 안 쓰는 페이지도 있을 수 있어, "정의돼 있다"가 아니라 "불렀다"를 신호로 삼는다)
    /// `WKScriptMessageHandler`로 알릴 메시지 이름. 앱 쪽이 이 이름으로
    /// `userContentController.add(_:name:)`를 걸어야 실제로 도착한다 — 여기서는
    /// 이름만 정한다(Kit은 WebKit을 모른다).
    public static let audioNeededMessageName = "wallflowAudioNeeded"

    /// `applyUserProperties`에 줄 JSON. WE 스펙대로 각 값을 `{"value": …}`로 감싼다 —
    /// 실물 스크립트가 `properties.foo.value`로 읽는다.
    public static func propertiesJSON(_ values: [String: UserPropertyValue]) -> String {
        var wrapped: [String: Any] = [:]
        for (name, value) in values {
            wrapped[name] = ["value": jsonValue(for: value)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// `UserProperty`는 콤보 값을 전부 문자열로 정규화해 둔다(씬 쪽의 JS 조건식
    /// 평가, 예: `mode.value === "clock"`, 는 그래야 한다). 하지만 실물 WE는
    /// project.json에 적힌 타입 그대로 보낸다 — 콤보 옵션 값이 숫자면 숫자로.
    /// 실물 893418273의 `backgroundsource` 콤보가 project.json에 1~4 숫자로 있는데
    /// 문자열 "1"로 보내면, 페이지의 `switch (properties.backgroundsource.value) {
    /// case 1: ... }`가 (`"1" === 1`이 거짓이라) 전부 비교에 실패해 `imageBackground`
    /// 같은 변수가 끝내 선언되지 않고 ReferenceError로 applyUserProperties 중간에
    /// 죽는다 — 그 뒤에 오는 모든 속성 설정이 통째로 안 먹혔다. 숫자로 온전히
    /// 파싱되는 문자열만 되돌린다 — "clock" 같은 진짜 문자열 콤보는 그대로 둔다.
    private static func jsonValue(for value: UserPropertyValue) -> Any {
        guard case .text(let s) = value else { return value.sceneJSONValue }
        if let intValue = Int(s) { return intValue }
        if let doubleValue = Double(s) { return doubleValue }
        return s
    }

    /// 페이지가 다 뜬 뒤(딱 한 번) evaluate할 JS. 페이지가 자기 손으로
    /// `window.wallpaperPropertyListener`를 안 만들었으면 조용히 아무 일도 하지 않는다.
    public static func applyPropertiesJS(_ values: [String: UserPropertyValue]) -> String {
        """
        (function() {
            var l = window.wallpaperPropertyListener;
            if (l && typeof l.applyUserProperties === 'function') {
                l.applyUserProperties(\(propertiesJSON(values)));
            }
        })();
        """
    }

    /// 문서 시작 시(페이지 자신의 스크립트보다 먼저) 주입해야 하는 부트스트랩.
    /// 등록 창구만 만들어 둔다 — 실물 페이지는 "있으면 쓴다"거나(`if (window.x)`)
    /// 아예 조건 없이 부른다. 존재하는 것 자체가 계약이다.
    public static var bootstrapJS: String {
        """
        (function() {
            if (window.wallpaperRegisterAudioListener) { return; }
            var audioListeners = [];
            window.wallpaperRegisterAudioListener = function(cb) {
                if (typeof cb !== 'function') { return; }
                audioListeners.push(cb);
                // 실제로 등록이 일어난 순간에만 앱 쪽에 알린다 — 페이지가
                // 오디오 API를 쓸지 안 쓸지는 이 호출 전에는 알 수 없다.
                try {
                    window.webkit.messageHandlers.\(audioNeededMessageName).postMessage(true);
                } catch (e) {}
            };
            window.__wallflowDispatchAudio = function(data) {
                audioListeners.forEach(function(cb) {
                    try { cb(data); } catch (e) {}
                });
            };
            var mediaListeners = [];
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {
                if (typeof cb === 'function') { mediaListeners.push(cb); }
            };
            // 슬라이드쇼 속성(폴더에서 무작위 파일 고르기)을 쓰는 페이지가 있다
            // (1081733658, 893418273 — 둘 다 조건부 호출이라 기본값에서는 안 걸리지만,
            // 사용자가 슬라이드쇼를 켜면 곧장 ReferenceError로 멎는다). 디렉터리
            // 선택 UI가 없으니 "없다"고 답한다 — 콜백을 아예 안 부르면 페이지가
            // 계속 기다리므로, null로 곧장 불러 준다.
            window.wallpaperRequestRandomFileForProperty = function(propertyName, cb) {
                if (typeof cb === 'function') { cb(propertyName, null); }
            };
        })();
        """
    }

    /// 오디오 콜백에 뿌릴 128개 배열(왼쪽 64 + 오른쪽 64 — WE 스펙과 실물
    /// 스크립트(893418273)가 `audioArray[0..63]`만 읽는 것으로 확인한 순서다)을
    /// 만들어 등록된 콜백들에 넘기는 JS.
    public static func dispatchAudioJS(left: [Float], right: [Float]) -> String {
        let combined = (left + right).map { $0.isFinite ? $0 : 0 }
        let values = combined.map { String(format: "%.4f", $0) }.joined(separator: ",")
        return "window.__wallflowDispatchAudio && window.__wallflowDispatchAudio([\(values)]);"
    }

    /// `WALLFLOW_WEB_DEBUG`가 켜졌을 때, 페이지가 뜨고 잠시 뒤 실제로 뭔가
    /// 그려졌는지 한 번에 찍어 보는 JS. 흰/검은 화면 신고가 들어오면 이걸로
    /// canvas 크기·rAF 동작·실제 픽셀 유무·WebGL 상태를 한 번에 본다 —
    /// 1748506393(유체 시뮬레이션) 진단에 실제로 썼다: canvas는 올바른 크기고
    /// requestAnimationFrame도 매끄럽게 돌고 gl.getError()도 0인데, **전체
    /// 캔버스를 스캔하면 픽셀이 한 개도 안 채워져 있었다** — 그리기 호출 자체는
    /// 성공하는데 결과가 비어 있는, 셰이더/텍스처 포맷 수준의 문제라는 뜻이다
    /// (원인은 못 찾았다 — 아래 첫 캔버스만 본다).
    public static let debugDiagnosticsJS = """
    (function() {
        var c = document.querySelector('canvas');
        if (!c) { return 'no-canvas'; }
        var out = { size: c.width + 'x' + c.height, inner: window.innerWidth + 'x' + window.innerHeight };
        try {
            var snap = document.createElement('canvas');
            snap.width = c.width; snap.height = c.height;
            var ctx2d = snap.getContext('2d');
            ctx2d.drawImage(c, 0, 0);
            var full = ctx2d.getImageData(0, 0, c.width, c.height).data;
            var maxRGB = 0, nonZeroPixels = 0;
            for (var i = 0; i < full.length; i += 4) {
                var m = Math.max(full[i], full[i + 1], full[i + 2]);
                if (m > maxRGB) { maxRGB = m; }
                if (m > 0) { nonZeroPixels++; }
            }
            out.maxRGB = maxRGB;
            out.nonZeroPixels = nonZeroPixels + '/' + (full.length / 4);
        } catch (e) { out.snapshotError = String(e); }
        var gl = c.getContext('webgl2') || c.getContext('webgl');
        out.gl = gl ? { lost: gl.isContextLost(), error: gl.getError() } : 'no-webgl';
        return JSON.stringify(out);
    })();
    """
}
