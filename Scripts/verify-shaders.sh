#!/bin/bash
# 실물 셰이더를 번역해 Metal이 컴파일하는지 잰다.
#
# 번역기의 진짜 판정 기준이다 — "번역했다"는 자기 보고와 다르다.
# 순수 텍스트 테스트(GLSLTranslatorTests)는 각 규칙을 고정하지만,
# 실제로 컴파일되는지는 assets 셰이더 전체로만 알 수 있다.
#
#   ./Scripts/verify-shaders.sh ~/Library/Application\ Support/Wallflow/Assets
#
# 2026-09-06 기준: 346개 중 339개(98%) 통과. 남은 7개는 HLSL식 암묵적 벡터 절단이
# 대입문에 나오는 형태로, 표현식을 이해하는 변환이 필요하다.
set -euo pipefail
ASSETS="${1:-$HOME/Library/Application Support/Wallflow/Assets}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
WALLFLOW_TEST_ASSETS="$ASSETS" WALLFLOW_MSL_DIR="$OUT/msl" \
    swift test --filter ShaderTranslationProbe 2>&1 | grep -E "^TRANSLATED" || true
echo "번역 결과: $OUT/msl"
