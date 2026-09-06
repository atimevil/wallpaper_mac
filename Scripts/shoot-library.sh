#!/bin/bash
# 라이브러리의 배경화면을 하나씩 띄워 화면을 찍는다.
#
# 씬 하나만 보고 고치면 다른 씬에서 같은 결함이 그대로 남는다. 전부 찍어
# 나란히 놓고 봐야 "이건 이 씬만의 문제가 아니다"가 보인다.
#
#   ./Scripts/shoot-library.sh [출력폴더] [씬당 대기초]
set -euo pipefail

OUT="${1:-/tmp/wallflow-shots}"
WAIT="${2:-9}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wallflow.app/Contents/MacOS/Wallflow"
LIBRARY="$HOME/Library/Application Support/Wallflow/Library"

[ -x "$APP" ] || { echo "먼저 ./Scripts/bundle.sh로 앱을 만들어라: $APP"; exit 1; }
mkdir -p "$OUT"

# 지금 걸려 있는 배경화면을 기억해 두고 끝나면 되돌린다.
BEFORE="$(defaults read dev.timevil.wallflow wallflow.lastSelectedID 2>/dev/null || echo '')"
restore() {
    pkill -f Wallflow.app/Contents/MacOS/Wallflow 2>/dev/null || true
    if [ -n "$BEFORE" ]; then
        defaults write dev.timevil.wallflow wallflow.lastSelectedID -string "$BEFORE"
    fi
    open "$ROOT/build/Wallflow.app" 2>/dev/null || true
}
trap restore EXIT

# 배경화면 창의 번호. 가장 넓은 것이 그것이다.
WINDOW_SWIFT="$(mktemp /tmp/wfwindow.XXXXXX.swift)"
cat > "$WINDOW_SWIFT" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var best = (id: 0, area: 0.0)
for window in list where (window[kCGWindowOwnerName as String] as? String) == "Wallflow" {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let number = window[kCGWindowNumber as String] as? Int else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > best.area { best = (number, area) }
}
print(best.id)
SWIFT

for entry in "$LIBRARY"/*; do
    id="$(basename "$entry")"
    title="$(python3 -c "
import json,sys
try: print(json.load(open('$entry/project.json')).get('title') or '')
except Exception: print('')
" 2>/dev/null)"
    pkill -f Wallflow.app/Contents/MacOS/Wallflow 2>/dev/null || true
    sleep 1
    defaults write dev.timevil.wallflow wallflow.lastSelectedID -string "$id"
    "$APP" > "$OUT/$id.log" 2>&1 &
    sleep "$WAIT"
    window="$(swift "$WINDOW_SWIFT" 2>/dev/null | tail -1)"
    if [ "${window:-0}" != "0" ]; then
        screencapture -x -o -l "$window" "$OUT/$id.png"
        sips -Z 900 "$OUT/$id.png" --out "$OUT/$id.small.png" > /dev/null 2>&1 || true
    fi
    echo "$id  $title"
done
rm -f "$WINDOW_SWIFT"
echo "찍은 곳: $OUT"
