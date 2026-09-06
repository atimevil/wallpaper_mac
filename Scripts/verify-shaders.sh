#!/bin/bash
# 실물 셰이더를 번역해 Metal이 컴파일하는지 잰다.
#
# 번역기의 진짜 판정 기준이다 — "번역했다"는 자기 보고와 다르다.
# 순수 텍스트 테스트(GLSLTranslatorTests)는 각 규칙을 고정하지만,
# 실제로 컴파일되는지는 assets 셰이더 전체로만 알 수 있다.
#
#   ./Scripts/verify-shaders.sh ~/Library/Application\ Support/Wallflow/Assets
#
# 두 번째 인자로 씬 디렉터리를 주면 pkg 안의 창작마당 이펙트도 함께 번역한다.
#
# 2026-09-06 기준: assets 346개 중 339개, 창작마당 106개 중 98개 — 합계 452개 중
# 437개(97%)가 컴파일된다. 남은 15개는 HLSL식 암묵적 벡터 절단이 대입문에 나오는
# 형태(표현식을 이해하는 변환이 필요)와 오디오 비주얼라이저다.
set -euo pipefail
ASSETS="${1:-$HOME/Library/Application Support/Wallflow/Assets}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
WALLFLOW_TEST_ASSETS="$ASSETS" WALLFLOW_MSL_DIR="$OUT/msl" \
    swift test --filter ShaderTranslationProbe 2>&1 | grep -E "^TRANSLATED" || true
# 씬 pkg 안의 창작마당 이펙트도 잰다. 가장 많이 쓰는 shimmer가 여기 있다.
if [ -n "${2:-}" ]; then
    WALLFLOW_TEST_SCENES="$2" WALLFLOW_TEST_ASSETS="$ASSETS" WALLFLOW_MSL_DIR="$OUT/msl" \
        swift test --filter WorkshopShaderProbe 2>&1 | grep -E "^WS_TRANSLATED" || true
fi
echo "번역 결과: $OUT/msl"
