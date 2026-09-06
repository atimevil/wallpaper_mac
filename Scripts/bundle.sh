#!/bin/bash
# .app 번들을 조립한다. SwiftPM은 실행 파일만 만들기 때문에 필요하다.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wallflow.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/WallflowApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wallflow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wallflow</string>
    <key>CFBundleDisplayName</key><string>Wallflow</string>
    <key>CFBundleIdentifier</key><string>dev.timevil.wallflow</string>
    <key>CFBundleExecutable</key><string>Wallflow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 서명 없이는 일부 API가 막히므로 서명한다.
#
# **임시(ad-hoc) 서명은 다시 만들 때마다 신원이 바뀐다.** macOS의 접근 권한은
# 서명의 해시로 앱을 알아보므로, 빌드할 때마다 "다운로드 폴더에 접근하려고
# 합니다"를 다시 묻는다 — 허용해도 다음 빌드에 또 묻는다.
#
# 자체 서명 인증서가 하나 있으면 신원이 고정돼 한 번 허용한 것이 계속 간다.
# 만드는 법(한 번만):
#   1. 키체인 접근 → 메뉴의 인증서 지원 → 인증서 생성
#   2. 이름 `Wallflow Dev`, 신원 유형 `자체 서명 루트`, 인증서 유형 `코드 서명`
#   3. 만든 뒤 `WALLFLOW_SIGN_IDENTITY="Wallflow Dev" ./Scripts/bundle.sh`
# 이름이 다르면 그 이름을 환경변수로 주면 된다. 없으면 예전처럼 ad-hoc이다.
IDENTITY="${WALLFLOW_SIGN_IDENTITY:-Wallflow Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "signed as: $IDENTITY (권한이 빌드마다 초기화되지 않는다)"
else
    codesign --force --deep --sign - "$APP"
    echo "signed ad-hoc (빌드마다 폴더 접근 권한을 다시 묻는다. 위 주석 참고)"
fi
echo "built: $APP"
