import Foundation

/// 사용자의 로컬 동영상 파일을 배경화면 라이브러리에 넣고 뺀다.
///
/// 라이브러리 항목은 창작마당이든 로컬이든 `<root>/<id>/project.json` 한 단위다
/// (`LibraryStore.scan`이 그대로 발견한다 — 새 렌더 경로를 만들지 않는다).
/// 로컬 항목은 `id`가 `local-` 접두사이고 project.json에 `wallflow_local: true`
/// 마커가 있어, 삭제할 때 창작마당 링크·사용자 수동 폴더와 확실히 구별된다.
///
/// AVFoundation(썸네일)·AppKit(파일 패널)은 App 계층이 맡는다. 여기(Kit)는
/// 순수 파일·JSON만 다뤄 경계를 지킨다.
public enum LocalVideoImporter {
    /// project.json에 박는 "이건 Wallflow가 만든 로컬 영상" 표시.
    public static let localMarker = "wallflow_local"
    /// 로컬 항목 id 접두사. 숫자뿐인 창작마당 id와 겹치지 않는다.
    public static let idPrefix = "local-"

    public enum LocalVideoError: Error, Equatable {
        /// 로컬 영상 항목이 아니다 — 지우기를 거부한다.
        case notALocalVideo
    }

    /// id만으로 로컬 항목인지(접두사) 가볍게 본다. UI에서 삭제를 보일지 고를 때 쓴다.
    /// 실제 삭제는 `deleteLocal`이 마커까지 확인한다.
    public static func isLocal(_ item: WallpaperItem) -> Bool {
        item.id.hasPrefix(idPrefix)
    }

    /// 로컬 동영상을 라이브러리에 추가한다.
    ///
    /// 원본을 **복사**한다(옮기거나 지우지 않는다). `project.json`은 **맨 마지막에**
    /// 써서, 복사가 중간에 실패하면 발견되기 전에 폴더째 정리한다.
    @discardableResult
    public static func importVideo(
        from source: URL, title: String?, into root: URL
    ) throws -> WallpaperItem {
        let fm = FileManager.default
        var ext = source.pathExtension
        if ext.isEmpty { ext = "mp4" }  // 확장자 없으면 mp4로 가정(AVFoundation이 대개 연다)

        let id = idPrefix + UUID().uuidString
        let dir = root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let fileName = "video.\(ext)"
            try fm.copyItem(at: source, to: dir.appendingPathComponent(fileName))

            let name = (title?.isEmpty == false)
                ? title!
                : source.deletingPathExtension().lastPathComponent
            let json: [String: Any] = [
                "type": "video",
                "file": fileName,
                "title": name,
                localMarker: true,
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            // 맨 마지막: 이게 있어야 LibraryStore가 폴더를 항목으로 본다.
            try data.write(to: dir.appendingPathComponent("project.json"))

            return try WallpaperItem.load(from: dir)  // 기존 로더로 검증하며 만든다
        } catch {
            try? fm.removeItem(at: dir)  // 깨진 폴더를 남기지 않는다
            throw error
        }
    }

    /// 로컬 영상 항목을 지운다. 세 가드를 **전부** 통과해야 지운다 —
    /// 창작마당 심볼릭 링크나 사용자가 직접 넣은 폴더는 절대 건드리지 않는다.
    public static func deleteLocal(_ item: WallpaperItem, root: URL) throws {
        let fm = FileManager.default
        let dir = item.directory

        // (a) 심볼릭 링크가 아니어야 한다. attributesOfItem은 링크를 따라가지 않아
        //     링크면 .typeSymbolicLink를 준다(창작마당 설치 링크를 거른다).
        let attrs = try fm.attributesOfItem(atPath: dir.path)
        guard (attrs[.type] as? FileAttributeType) != .typeSymbolicLink else {
            throw LocalVideoError.notALocalVideo
        }

        // (b) 라이브러리 root 바로 아래여야 한다.
        let parent = dir.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.resolvingSymlinksInPath().path else {
            throw LocalVideoError.notALocalVideo
        }

        // (c) project.json에 우리 마커가 있어야 한다.
        let projectURL = dir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj[localMarker] as? Bool == true else {
            throw LocalVideoError.notALocalVideo
        }

        try fm.removeItem(at: dir)
    }
}
