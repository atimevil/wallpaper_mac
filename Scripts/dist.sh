#!/bin/bash
# 배포용 .app과 .dmg를 만든다. bundle.sh가 하는 빌드+서명 위에
# 공증(선택)과 DMG 포장, 로컬 검증을 얹는다.
#
#   ./Scripts/dist.sh
#
# 서명 신원
#   WALLFLOW_SIGN_IDENTITY를 주면 그 신원으로 서명한다 (배포하려면 Apple
#   Developer ID 인증서여야 한다 — "Developer ID Application: 이름 (팀ID)").
#   안 주면 bundle.sh가 쓰는 자체 서명 "Wallflow Dev" 경로로 떨어진다.
#   자체 서명은 이 기계 밖에서 열리지 않는다 — 배포가 아니라 로컬 검증용이다.
#
# 공증 (선택, WALLFLOW_NOTARIZE=1)
#   Developer ID로 서명한 빌드만 의미가 있다. 자격 증명은 이 스크립트가
#   절대 묻거나 담지 않는다 — 한 번만 미리 keychain에 넣어 둔다:
#
#     xcrun notarytool store-credentials "wallflow-notary" \
#       --apple-id "you@example.com" --team-id TEAMID --password "앱 암호"
#
#   그 프로필 이름을 WALLFLOW_NOTARY_PROFILE로 준다 (기본값 "wallflow-notary").
#
#     WALLFLOW_SIGN_IDENTITY="Developer ID Application: ..." \
#     WALLFLOW_NOTARIZE=1 WALLFLOW_NOTARY_PROFILE="wallflow-notary" \
#     ./Scripts/dist.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=version.sh
source "$ROOT/Scripts/version.sh"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Wallflow.app"
DMG_NAME="Wallflow-$WALLFLOW_VERSION.dmg"
DMG="$BUILD_DIR/$DMG_NAME"
STAGING="$BUILD_DIR/dmg-staging"

echo "== 1. 릴리스 빌드 + 서명 (bundle.sh) =="
"$ROOT/Scripts/bundle.sh" release

# bundle.sh가 이미 서명 여부/신원을 알려 줬다. 여기서는 어떤 경로였는지만 다시 잰다
# (공증 전에 자체 서명이면 건너뛰기 위해).
IDENTITY="${WALLFLOW_SIGN_IDENTITY:-Wallflow Dev}"
# `-v`를 쓰지 않는다. 자체 서명 인증서는 신뢰 목록에 없어 "유효"로 세어지지 않지만
# 서명에는 쓰인다(bundle.sh의 같은 주석 참고).
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGNED_WITH="$IDENTITY"
else
    SIGNED_WITH="-"
fi

echo "== 2. DMG 포장 =="
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Wallflow" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
echo "만듦: $DMG"

echo "== 3. 공증 =="
if [ "${WALLFLOW_NOTARIZE:-0}" = "1" ]; then
    if [ "$SIGNED_WITH" = "-" ]; then
        echo "건너뜀: 자체 서명(ad-hoc) 빌드는 공증 대상이 아니다 (Developer ID 서명이 있어야 한다)."
    else
        PROFILE="${WALLFLOW_NOTARY_PROFILE:-wallflow-notary}"
        echo "notarytool 제출 중 (프로필: $PROFILE)…"
        xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "공증 완료, DMG에 스테이플링함"
    fi
else
    echo "건너뜀: WALLFLOW_NOTARIZE=1이 아니다"
fi

echo "== 4. 로컬 검증 (Developer ID 없이 되는 것만) =="
MOUNT_POINT="$(mktemp -d "$BUILD_DIR/dmg-verify.XXXXXX")"
hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
cleanup_mount() { hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rmdir "$MOUNT_POINT" 2>/dev/null || true; }
trap cleanup_mount EXIT

MOUNTED_APP="$MOUNT_POINT/Wallflow.app"

echo "--- codesign --verify --deep --strict ---"
if codesign --verify --deep --strict "$MOUNTED_APP" 2>&1; then
    echo "통과: 서명 구조가 유효하다 (자체 서명이라도 코드사인 자체는 잰다)."
else
    echo "실패: 서명 검증에 걸렸다."
fi

echo "--- spctl --assess (Gatekeeper) ---"
if spctl --assess --type execute -v "$MOUNTED_APP" 2>&1; then
    echo "통과: Gatekeeper가 이 앱을 받아들인다."
else
    echo "예상된 실패: 자체 서명이나 공증 없는 빌드는 Gatekeeper가 막는다."
    echo "  → Developer ID 서명 + 공증(WALLFLOW_NOTARIZE=1) 없이는 여기까지가 로컬 한계다."
fi

echo
echo "== 요약 =="
echo "서명 신원: $SIGNED_WITH"
echo "DMG: $DMG"
if [ "$SIGNED_WITH" = "-" ] || ! security find-identity -v -p codesigning 2>/dev/null | grep -qi "Developer ID"; then
    echo "Developer ID 인증서가 없다: 코드사인 구조 검증까지는 로컬에서 확인되지만,"
    echo "Gatekeeper 통과·공증·다른 기계에서 실행은 Apple Developer 계정의"
    echo "Developer ID Application 인증서가 있어야 한다."
fi
