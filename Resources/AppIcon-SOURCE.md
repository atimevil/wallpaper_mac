# 앱 아이콘 출처

`AppIcon.icns`는 우타가와 히로시게(歌川広重)의 목판화 「아와 나루토의 소용돌이」
(Naruto Whirlpool, Awa Province, 『육십여주 명소도회』 연작, 1853년경)의 아래쪽 소용돌이를 잘라 만들었다.

- 소장: The Metropolitan Museum of Art, object 53783
  <https://www.metmuseum.org/art/collection/search/53783>
- 이미지: `https://images.metmuseum.org/CRDImages/as/original/DP122165.jpg`
- 라이선스: 메트 미술관 Open Access — 퍼블릭 도메인(CC0). 미술관 API의 `isPublicDomain: true`를 확인했다.

## 다시 만들기

```sh
swiftc -O -o /tmp/make-icon Scripts/make-icon.swift
/tmp/make-icon DP122165.jpg 598 2390 1300 icon.png      # x y 변(원본 픽셀)
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

`make-icon`은 정사각형으로 자른 그림을 macOS 아이콘 틀(1024 캔버스, 824 몸체, 둥근 모서리, 옅은 그림자,
바깥은 투명)에 넣기만 한다. 그림은 원화 그대로다.

## 다른 후보

`docs/icon/candidates.png` — 같은 방식으로 만든 후보 셋(256·64·32px). 모두 메트 미술관 CC0.

| 후보 | 작품 | 메트 번호 | 자른 곳(x y 변) |
|---|---|---|---|
| 1 | 가쓰시카 호쿠사이 「가나가와 해변의 높은 파도」(1830–32년경) | 45434 | 640 200 1700 |
| 2 | 빈센트 반 고흐 「사이프러스가 있는 밀밭」(1889) | 436535 | 2057 143 1714 |
| 3 (사용 중) | 우타가와 히로시게 「아와 나루토의 소용돌이」(1853년경) | 53783 | 598 2390 1300 |

작은 크기(32px)에서 모양이 가장 또렷하고 이름("흐름")과 맞아 3을 골랐다.
