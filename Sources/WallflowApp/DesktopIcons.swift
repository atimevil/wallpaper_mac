import Foundation

/// 바탕화면 아이콘을 숨기거나 보인다.
///
/// macOS에 공개 API가 없어, 파인더의 `CreateDesktop` 설정을 바꾸고 파인더를 다시
/// 띄우는 표준 방식을 쓴다. **파인더 창이 잠깐 닫혔다 열린다** — 토글의 알려진 비용.
enum DesktopIcons {
    /// 지금 숨겨져 있나. **우리 설정이 아니라 실제 파인더 설정을 읽는다** — 손으로
    /// 바꾸거나 다른 앱이 토글해도 메뉴 체크 표시가 거짓말하지 않게.
    static var isHidden: Bool {
        parseHidden(fromCreateDesktop:
            capture("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"]))
    }

    static func setHidden(_ hidden: Bool) {
        // CreateDesktop=false면 아이콘이 사라진다.
        run("/usr/bin/defaults",
            ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        run("/usr/bin/killall", ["Finder"])
    }

    /// `defaults read`의 출력으로 숨김 여부를 판정한다(순수 — 쉘 없이 시험 가능).
    /// `"0"`이면 숨김. `"1"`이면 보임. 키가 없어 nil/빈 값이면 **보이는 상태**가
    /// 기본이다(그동안 사람들이 틀렸던 자리).
    static func parseHidden(fromCreateDesktop output: String?) -> Bool {
        output?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 표준 출력을 문자열로. 실행 실패·키 없음(비정상 종료)이면 nil.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
