import AppKit

extension NSAlert {
    /// 되돌릴 수 없는 일을 묻는 확인창용. "취소"에 Return을 주면(실수로 지우지 않게) 그 버튼의
    /// 키가 Return으로 바뀌어 Esc가 아무 일도 안 한다 — 버튼 하나는 키 하나만 가진다(실측).
    /// 그래서 창이 떠 있는 동안 Esc를 따로 잡아 `escape` 결과로 닫는다.
    @MainActor
    func runModal(escapeReturns escape: NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            NSApp.stopModal(withCode: escape)
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            // 버튼으로 닫힐 때와 달리 stopModal로 끝나면 창이 남는다.
            window.orderOut(nil)
        }
        return runModal()
    }
}
