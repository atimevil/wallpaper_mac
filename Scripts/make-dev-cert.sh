#!/bin/bash
# 개발용 자체 서명 인증서를 만든다. **한 번만 하면 된다.**
#
# 왜 필요한가: 임시(ad-hoc) 서명은 빌드할 때마다 해시가 바뀐다. macOS의 접근 권한
# (TCC)은 그 해시로 앱을 알아보므로, 빌드마다 "화면 기록 권한이 필요합니다 →
# 시스템 설정 열기"와 "폴더에 접근하려고 합니다"를 처음부터 다시 묻는다.
# 인증서로 서명하면 신원이 고정되어 한 번 허용한 것이 계속 간다.
#
# 이 인증서는 **Gatekeeper를 통과시키지 못한다.** 남에게 배포하려면 Apple의
# Developer ID가 필요하다(Scripts/dist.sh 참고). 이건 이 맥에서 내가 쓰려고
# 만드는 것이다.
#
# 지우려면:  security delete-certificate -c "Wallflow Dev" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="${1:-Wallflow Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "이미 있다: $NAME"
    echo "이제 ./Scripts/bundle.sh 가 이 신원으로 서명한다."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 코드 서명용 확장(EKU)이 있어야 codesign이 쓸 수 있다.
cat > "$WORK/openssl.cnf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = PLACEHOLDER
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
sed -i '' "s/PLACEHOLDER/$NAME/" "$WORK/openssl.cnf"

# **애플의 openssl(LibreSSL)을 쓴다.** Homebrew의 OpenSSL 3은 PKCS#12를 새 방식
# (AES-256/PBKDF2)으로 싸는데, macOS 키체인이 그것을 못 읽고
# "MAC verification failed"로 거절한다.
OPENSSL=/usr/bin/openssl
PASS="wallflow-dev-임시"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -out "$WORK/id.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASS" 2>/dev/null

# `-T /usr/bin/codesign`: codesign이 이 키를 쓸 때마다 묻지 않게 미리 허용한다.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# 키 접근 목록을 확정한다. 이 한 줄이 없으면 서명할 때마다 키체인 창이 뜬다.
# 로그인 암호를 물을 수 있다 — 이 맥의 사용자 암호이고, 어디로도 보내지 않는다.
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "참고: 키 접근 목록을 자동으로 못 정했다."
    echo "      서명할 때 키체인 창이 뜨면 '항상 허용'을 한 번 누르면 된다."
fi

echo "만들었다: $NAME"
security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null && echo "키체인에 있음"
echo
echo "이제 ./Scripts/bundle.sh 를 다시 돌리면 이 신원으로 서명한다."
echo "그 뒤 권한을 한 번만 허용하면 다음 빌드부터는 다시 묻지 않는다."
