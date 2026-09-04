/// 렌더러에게 내리는 재생 지시.
public enum PlaybackDirective: Equatable, Sendable {
    case paused
    case playing(fps: Int)
}
