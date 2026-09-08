#!/bin/bash
# .app 번들을 조립한다. SwiftPM은 실행 파일만 만들기 때문에 필요하다.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wallflow.app"
# shellcheck source=version.sh
source "$ROOT/Scripts/version.sh"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/WallflowApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wallflow"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wallflow</string>
    <key>CFBundleDisplayName</key><string>Wallflow</string>
    <key>CFBundleIdentifier</key><string>$WALLFLOW_BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Wallflow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$WALLFLOW_VERSION</string>
    <key>CFBundleVersion</key><string>$WALLFLOW_BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- AudioSpectrum.swift가 SCStream(capturesAudio: true)로 시스템 소리를 듣는다.
         마이크가 아니라 화면·시스템 오디오 녹화 권한(kTCCServiceAudioCapture) 아래
         있고, 사용자가 오디오 반응을 켜기 전에는 요청하지 않는다. -->
    <key>NSAudioCaptureUsageDescription</key><string>배경화면의 오디오 비주얼라이저가 지금 나고 있는 시스템 소리의 크기만 읽어 화면에 반영합니다. 소리를 저장하거나 어디로 보내지 않습니다.</string>
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
# `-v`(유효한 것만)를 쓰지 않는다. 자체 서명 인증서는 신뢰 목록에 없어서 "유효"로
# 세어지지 않지만, **서명에는 그대로 쓸 수 있다.** `-v`로 찾으면 인증서를 만들어
# 두고도 계속 ad-hoc으로 서명해 권한이 매번 초기화된다.
# 인증서가 없으면 `./Scripts/make-dev-cert.sh`로 한 번 만들면 된다.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "signed as: $IDENTITY (권한이 빌드마다 초기화되지 않는다)"
    codesign -d -r- "$APP" 2>&1 | grep "^designated" || true
else
    codesign --force --deep --sign - "$APP"
    echo "signed ad-hoc (빌드마다 권한을 다시 묻는다. ./Scripts/make-dev-cert.sh 참고)"
fi
echo "built: $APP"
