import Foundation
import ServiceManagement

/// 로그인할 때 앱이 스스로 뜨게 한다.
///
/// 배경화면 앱이 재부팅 뒤에 안 뜨면 매번 손으로 켜야 한다. macOS 13부터
/// `SMAppService.mainApp`으로 로그인 항목을 앱이 직접 등록할 수 있다 —
/// 예전처럼 별도 헬퍼 앱을 번들에 넣지 않아도 된다.
///
/// 등록은 사용자가 켤 때만 한다. 배경화면을 한 번 띄웠다고 로그인 항목에
/// 몰래 들어가 있으면 그건 사용자가 동의한 적 없는 변경이다.
@MainActor
enum LoginItem {
    /// 지금 로그인 항목으로 등록되어 있는지.
    ///
    /// 사용자가 시스템 설정에서 직접 끌 수도 있으므로, 우리가 저장한 값이 아니라
    /// 시스템에 물어본다. 둘이 어긋나면 메뉴 체크 표시가 거짓말을 하게 된다.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자가 직접 끈 경우. 시스템 설정에서만 다시 켤 수 있다.
    static var isDeniedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: 실패 이유. 성공이면 nil.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // 개발 중 서명 없는 번들에서는 실패한다. 앱을 죽이지 않고 이유만 알린다.
            return "\(error.localizedDescription)"
        }
    }
}
