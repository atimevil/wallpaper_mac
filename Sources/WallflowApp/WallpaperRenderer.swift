import AppKit
import WallflowKit

enum RendererError: Error {
    case unsupportedType(WallpaperType)
    /// 열 수 없는 배경화면. 이유를 함께 들고 있는다 — 조용히 검은 화면을
    /// 내놓으면 사용자는 자기가 받은 것이 왜 안 뜨는지 알 수 없다.
    case unopenable(String)
    case contentMissing(URL)
    /// 씬은 열렸지만 그릴 수 있는 레이어가 하나도 없다. Metal 자체가 없는
    /// unsupportedType(.scene)과는 원인이 달라 구분한다.
    case noDrawableLayers
}

/// 배경화면 한 장을 그리는 것의 공통 인터페이스.
/// 소비자는 이것이 비디오인지 웹인지 씬인지 몰라도 된다.
/// 구현체는 전부 AppKit/WebKit/AVKit 뷰를 다루므로 메인 스레드 전용이다.
/// 프로토콜 수준에서 격리해 구현체마다 표시를 반복하지 않는다.
@MainActor
protocol WallpaperRenderer: AnyObject {
    /// 윈도우에 붙일 뷰를 만든다. start() 전에 호출된다.
    func makeView() -> NSView
    func start() throws
    /// 전력 정책의 결정을 반영한다.
    func apply(_ directive: PlaybackDirective)
    func stop()
}
