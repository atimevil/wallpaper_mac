# 번들 신원과 버전의 단일 출처.
#
# bundle.sh와 dist.sh가 둘 다 이 파일을 source한다. 여기 값을 바꾸면
# Info.plist·DMG 이름·shoot-library.sh가 참조하는 defaults 도메인이 한 번에 맞는다.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/version.sh"
WALLFLOW_BUNDLE_ID="dev.timevil.wallflow"
WALLFLOW_VERSION="0.1.0"
WALLFLOW_BUILD="1"
