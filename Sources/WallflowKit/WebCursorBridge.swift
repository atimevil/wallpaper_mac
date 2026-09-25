import Foundation
import CoreGraphics

/// 실물 데스크톱 마우스를 웹 배경화면 안 DOM 이벤트로 옮기는 순수 좌표 변환·JS 조각.
///
/// 실물 WE는 데스크톱이 드러나 있을 때(다른 창이 덮지 않을 때) 커서 움직임/클릭을
/// 웹 배경화면에 그대로 넘긴다 — 이 파일의 마우스 반응 스크립트(1748506393의
/// `canvas.addEventListener('mousemove', …)`, `mousedown`으로 스플랫을 찍는 로직)가
/// 그걸 전제로 짜여 있다. 좌표계가 세 겹 달라 순서대로 바꾼다:
/// 1) AppKit 전역 화면 좌표(왼쪽 아래 원점, y 위로 증가) — `NSEvent.mouseLocation`이 이 꼴.
/// 2) Quartz 창 목록 좌표(왼쪽 위 원점, y 아래로 증가) — `CGWindowListCopyWindowInfo`가
///    돌려주는 창 사각형이 이 꼴이라, "이 점을 덮은 창이 있나"를 그 좌표계에서 물어야 한다.
/// 3) 웹 페이지 DOM 좌표(웹뷰 왼쪽 위 원점, y 아래로 증가) — `MouseEvent.clientX/Y`가 이 꼴.
public enum WebCursorBridge {
    /// AppKit 화면 좌표 → Quartz 창 목록 좌표. 주 디스플레이(원점이 되는 화면)의
    /// 높이만 있으면 된다 — Quartz 전역 좌표의 원점이 그 화면의 왼쪽 위다.
    public static func quartzPoint(appKit point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// 전역 화면 좌표(창 프레임과 같은 좌표계 — 어느 쪽이든 일관되기만 하면 된다)를
    /// 웹뷰 안 페이지 좌표로 옮긴다. 웹뷰가 창을 통째로 채우므로 `windowFrame`이
    /// 곧 웹뷰의 화면상 사각형이다. 점이 그 사각형 밖이면 nil — 이 화면 담당이 아니다.
    public static func pagePoint(screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint? {
        guard windowFrame.width > 0, windowFrame.height > 0,
              windowFrame.contains(screenPoint) else { return nil }
        // 창 프레임은 AppKit 좌표(y 위로 증가)와 같은 방향이라 y를 뒤집어야
        // DOM 좌표(y 아래로 증가)가 된다.
        return CGPoint(x: screenPoint.x - windowFrame.minX, y: windowFrame.maxY - screenPoint.y)
    }

    /// 페이지 좌표 지점에 합성 마우스 이벤트를 쏘는 JS.
    /// `document.elementFromPoint`로 그 지점의 실제 엘리먼트를 찾아 거기 쏜다 —
    /// body에 뭉뚱그려 쏘면 `canvas.addEventListener`처럼 특정 엘리먼트에
    /// 리스너를 건 페이지가 못 받는다.
    public static func mouseEventJS(type: String, x: Double, y: Double, buttons: Int = 0) -> String {
        """
        (function() {
            var x = \(x), y = \(y);
            var el = document.elementFromPoint(x, y) || document.body || document.documentElement;
            if (!el) { return; }
            var ev = new MouseEvent('\(type)', {
                clientX: x, clientY: y, bubbles: true, cancelable: true,
                view: window, buttons: \(buttons)
            });
            el.dispatchEvent(ev);
        })();
        """
    }
}
