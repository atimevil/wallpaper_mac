import AppKit
import WallflowKit

enum RendererError: Error {
    case unsupportedType(WallpaperType)
    case contentMissing(URL)
}

/// 배경화면 한 장을 그리는 것의 공통 인터페이스.
/// 소비자는 이것이 비디오인지 웹인지 씬인지 몰라도 된다.
protocol WallpaperRenderer: AnyObject {
    /// 윈도우에 붙일 뷰를 만든다. start() 전에 호출된다.
    func makeView() -> NSView
    func start() throws
    /// 전력 정책의 결정을 반영한다.
    func apply(_ directive: PlaybackDirective)
    func stop()
}
