import Foundation

/// 씬의 참조를 두 단계로 해석한다. 배경화면이 들고 온 것이 먼저이고,
/// 없으면 Wallpaper Engine의 표준 에셋에서 찾는다.
public struct ReferenceResolver: Sendable {
    private let pkg: PkgReader
    private let assets: AssetsStore?

    public init(pkg: PkgReader, assets: AssetsStore?) {
        self.pkg = pkg
        self.assets = assets
    }

    /// 어느 쪽에도 없으면 nil. 참조가 끊긴 것은 정상 상태이므로 던지지 않는다.
    public func data(for name: String) -> Data? {
        if let data = try? pkg.data(for: name) { return data }
        guard let assets, assets.contains(name) else { return nil }
        return try? assets.data(for: name)
    }

    public func json(for name: String) -> [String: Any]? {
        guard let data = data(for: name),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
