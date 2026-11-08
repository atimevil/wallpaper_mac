import Foundation

/// 바탕화면 아이콘을 숨기거나 보인다.
///
/// macOS에 공개 API가 없어, 파인더의 `CreateDesktop` 설정을 바꾸고 파인더를 다시
/// 띄우는 표준 방식을 쓴다. **파인더 창이 잠깐 닫혔다 열린다** — 토글의 알려진 비용.
enum DesktopIcons {
    /// 지금 숨겨져 있나. **우리 설정이 아니라 실제 파인더 설정을 읽는다** — 손으로
    /// 바꾸거나 다른 앱이 토글해도 메뉴 체크 표시가 거짓말하지 않게.
    ///
    /// 메뉴를 열 때마다 불리므로 프로세스(`defaults read`)를 띄우지 않고 설정
    /// 데몬에서 바로 읽는다. 동기화를 먼저 해야 다른 프로세스가 방금 쓴 값이 보인다.
    /// 키가 없으면 **보이는 상태**가 기본이다.
    static var isHidden: Bool {
        let finder = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(finder)
        guard let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, finder)
        else { return false }
        return (value as? Bool) == false
    }

    static func setHidden(_ hidden: Bool) {
        // CreateDesktop=false면 아이콘이 사라진다.
        run("/usr/bin/defaults",
            ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        run("/usr/bin/killall", ["Finder"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
