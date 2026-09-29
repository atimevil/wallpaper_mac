import Foundation

/// 무한 스크롤 판단. 화면(AppKit)은 스크롤 뷰의 실측값만 넘기고, 언제 다음
/// 페이지를 요청할지·언제 그만둘지는 여기서 순수하게 정한다.
public enum WorkshopScrollPaging {
    /// 보이는 영역의 아래쪽이 전체 내용의 끝에서 `rowsBeforeEnd`줄 앞까지 왔으면
    /// 다음 페이지를 미리 요청한다. 끝에 닿고 나서 받으면 그 사이 사용자가
    /// 빈 바닥을 본다.
    public static func shouldLoadNextPage(
        visibleBottom: Double, contentHeight: Double, rowHeight: Double,
        rowsBeforeEnd: Int = 2
    ) -> Bool {
        guard rowHeight > 0 else { return false }
        return visibleBottom >= contentHeight - rowHeight * Double(rowsBeforeEnd)
    }

    /// 클라이언트 쪽 OR 필터 때문에 페이지 하나가 통째로 걸러져 새 칸이 0개일 때,
    /// 한 번 더 다음 페이지를 받을지. 연속 3회까지만 — 안 그러면 조건에 맞는
    /// 항목이 아예 없는 검색에서 끝없이 이어 받는다.
    public static func shouldRetryAfterEmptyPage(
        consecutiveEmptyPages: Int, maxRetries: Int = 3
    ) -> Bool {
        consecutiveEmptyPages < maxRetries
    }
}
