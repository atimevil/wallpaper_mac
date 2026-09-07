import Foundation

/// 씬의 참조를 두 단계로 해석한다. 배경화면이 들고 온 것이 먼저이고,
/// 없으면 Wallpaper Engine의 표준 에셋에서 찾는다.
public struct ReferenceResolver: Sendable {
    /// 바깥 파일을 가리키는 참조의 접두어. 뒤에 절대 경로가 온다.
    /// 텍스처 사용자 속성(프리셋의 `files/x.gif`)이 이 꼴로 씬에 들어온다.
    public static let externalPrefix = "@file:"
    /// 바깥 파일 읽기의 상한. 배경화면 그림 하나에 넉넉하고, 통째로 메모리에 올린다.
    public static let maxExternalBytes = 256 * 1024 * 1024

    private let pkg: PkgReader
    private let assets: AssetsStore?
    /// 바깥 파일을 읽어도 되는 폴더들. 이 밖의 절대 경로는 없는 것으로 본다 —
    /// 씬 JSON은 창작마당에서 온 텍스트라 아무 경로나 적을 수 있다.
    public var externalRoots: [URL] = []

    public init(pkg: PkgReader, assets: AssetsStore?, externalRoots: [URL] = []) {
        self.pkg = pkg
        self.assets = assets
        self.externalRoots = externalRoots
    }

    /// 어느 쪽에도 없으면 nil. 참조가 끊긴 것은 정상 상태이므로 던지지 않는다.
    public func data(for name: String) -> Data? {
        if name.hasPrefix(Self.externalPrefix) {
            return externalData(path: String(name.dropFirst(Self.externalPrefix.count)))
        }
        if let data = try? pkg.data(for: name) { return data }
        guard let assets, assets.contains(name) else { return nil }
        return try? assets.data(for: name)
    }

    /// 허용된 폴더 안의 파일만 읽는다. 링크를 따라간 뒤에 판정한다.
    private func externalData(path: String) -> Data? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = externalRoots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        guard allowed,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue <= Self.maxExternalBytes else { return nil }
        return try? Data(contentsOf: file)
    }

    public func json(for name: String) -> [String: Any]? {
        guard let data = data(for: name),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
