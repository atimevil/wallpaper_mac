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
        if let data = pkgData(for: name) { return data }
        guard let assets, assets.contains(name) else { return nil }
        return try? assets.data(for: name)
    }

    /// pkg **안에서만** 찾는다. Assets는 아예 안 본다.
    ///
    /// 셰이더처럼 "이 이름으로 못 찾으면 다른 철자로도 찾아본다" 하는 자리에서
    /// 쓴다 — 철자 후보를 순서대로 `data(for:)`에 넘기면 pkg에 있는 철자를
    /// 시도하기도 전에 Assets에만 있는 다른 철자가 먼저 걸려 배경화면이 들고
    /// 온 자기 사본 대신 엔진 표준판을 쓰게 된다(실물 워크숍 1493910771의
    /// waterwaves 이펙트 — 씬은 `shaders/effects/waterwaves.frag`로 담았는데,
    /// 첫 철자 후보 `effects/waterwaves/shaders/effects/waterwaves.frag`가
    /// pkg엔 없고 Assets에만 있어 그쪽이 먼저 걸렸다. Assets 판은 유니폼 이름이
    /// 바뀐 최신판이라 씬의 `constantshadervalues`가 하나도 안 먹혀 셰이더
    /// 기본값(격하게 강한 물결)으로 그려졌다). 호출자가 모든 철자를 pkg로 먼저
    /// 훑고, 그래도 없으면 `data(for:)`로 (pkg 재확인 겸) Assets까지 보게 한다.
    public func pkgData(for name: String) -> Data? {
        guard !name.hasPrefix(Self.externalPrefix) else { return nil }
        return try? pkg.data(for: name)
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

    /// 이름 철자 후보 여럿 중 하나를 찾는다. **pkg를 모든 철자에 대해 먼저
    /// 훑고**, 그래도 못 찾으면 그제야 `data(for:)`로(사실상 Assets까지) 다시
    /// 훑는다 — 철자마다 `data(for:)`를 바로 부르면 pkg에 있는 다른 철자보다
    /// Assets에만 있는 철자가 먼저 걸릴 수 있다(`pkgData(for:)` 참고).
    public func firstData(of candidates: [String]) -> Data? {
        for name in candidates {
            if let data = pkgData(for: name) { return data }
        }
        for name in candidates {
            if let data = data(for: name) { return data }
        }
        return nil
    }

    public func json(for name: String) -> [String: Any]? {
        guard let data = data(for: name),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
