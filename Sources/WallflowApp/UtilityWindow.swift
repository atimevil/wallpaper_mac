import AppKit

/// 메뉴 막대 전용 앱의 일반 창(창작마당·설정).
///
/// 이 앱엔 메인 메뉴(파일 › 닫기)가 없어 Cmd+W가 어디에도 닿지 않는다 —
/// 창이 직접 받아 닫는다.
final class UtilityWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, Self.isW(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 한글 입력기가 켜져 있으면 Cmd+W가 "ㅈ"으로 온다 — 메뉴라면 시스템이 영문으로
    /// 바꿔 주지만 여긴 메뉴가 없다. 글자가 영문이 아닐 때만 물리 키(W 자리)로 본다
    /// (드보락처럼 배치가 다른 영문 자판은 글자 "w"로 맞는다).
    private static func isW(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if chars == "w" { return true }
        return !chars.allSatisfy(\.isASCII) && event.keyCode == 13  // kVK_ANSI_W
    }
}
