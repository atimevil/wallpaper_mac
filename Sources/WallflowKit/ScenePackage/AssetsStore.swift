import Foundation

public enum AssetsError: Error, Equatable {
    case notFound(String)
    case escapesRoot(String)
    case unreadable(String)
}

/// Wallpaper Engine 설치 폴더의 `assets/` 디렉터리를 읽는다.
/// `.pkg`에 들어 있지 않은 표준 셰이더·기본 모델·파티클 텍스처가 여기 있다.
///
/// 참조 문자열은 씬 파일에서 오므로 적대적 입력이다. 경로를 정규화하고 심볼릭
/// 링크를 해석한 뒤, 루트 안에 있는지 확인해 `../`나 링크로 폴더 밖을 읽지
/// 못하게 막는다.
public struct AssetsStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// 참조 이름을 루트 안의 실제 경로로 바꾼다. 밖으로 나가면 nil.
    ///
    /// standardizedFileURL은 ../만 접고 심볼릭 링크는 해석하지 않는다.
    /// 에셋 폴더 안에 밖을 가리키는 링크가 있으면 그것만으로는 통과하므로,
    /// 양쪽을 resolvingSymlinksInPath()로 해석한 뒤 비교한다.
    private func resolve(_ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(name)
            .standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    public func contains(_ name: String) -> Bool {
        guard let url = resolve(name) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return !isDir.boolValue
    }

    public func data(for name: String) throws -> Data {
        guard let url = resolve(name) else { throw AssetsError.escapesRoot(name) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw AssetsError.notFound(name)
        }
        do {
            // mmap을 쓰지 않는다. 매핑 후 파일이 잘리면 SIGBUS로 죽는데 그것은
            // Swift 오류가 아니라 프로세스 종료라 잡을 수 없다. 에셋 파일은
            // 2935개에 85MB, 평균 29KB라 mmap이 얻는 것도 없다.
            // scene.pkg(최대 226MB)도 이제 예외가 아니다 — SteamCmdClient가 쓰는
            // 사용자 관리 파일이라 로딩 중 업데이트가 덮어쓸 수 있고, PkgReader가
            // 어차피 subdata로 항목을 통째로 복사하므로 매핑이 얻는 이득도 없다
            // (SceneRenderer.start() 참고).
            return try Data(contentsOf: url)
        } catch {
            throw AssetsError.unreadable(name)
        }
    }
}
