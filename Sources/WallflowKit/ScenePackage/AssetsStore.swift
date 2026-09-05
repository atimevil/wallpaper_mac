import Foundation

public enum AssetsError: Error, Equatable {
    case notFound(String)
    case escapesRoot(String)
    case unreadable(String)
}

/// Wallpaper Engine 설치 폴더의 `assets/` 디렉터리를 읽는다.
/// `.pkg`에 들어 있지 않은 표준 셰이더·기본 모델·파티클 텍스처가 여기 있다.
///
/// 참조 문자열은 씬 파일에서 오므로 적대적 입력이다. `../`로 에셋 폴더 밖을
/// 읽지 못하게 경로를 정규화한 뒤 루트 안에 있는지 확인한다.
public struct AssetsStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// 참조 이름을 루트 안의 실제 경로로 바꾼다. 밖으로 나가면 nil.
    private func resolve(_ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(name).standardizedFileURL
        // standardized가 ../를 접은 뒤에도 루트 밑에 있어야 한다.
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
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
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AssetsError.unreadable(name)
        }
    }
}
