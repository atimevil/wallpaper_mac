#!/usr/bin/env python3
"""창작마당 `.pkg`를 파이썬에서 읽는다. 씬 JSON을 눈으로 확인할 때 쓴다.

배치는 `Sources/WallflowKit/ScenePackage/PkgReader.swift`와 같다:

    int32 길이 + 바이트   버전 문자열("PKGV0023")
    int32                 항목 수
    항목마다: int32 길이 + 이름 · int32 오프셋 · int32 길이
    (표가 끝난 자리가 기준점, 항목 데이터는 기준점 + 오프셋)

**이 파일은 저장소 안에 있어야 한다.** 예전에는 `/tmp`에 두고 썼는데, 재부팅 한 번에
사라져서 다음 세션이 형식을 다시 알아내야 했다.

  ./Scripts/pkgdump.py <scene.pkg>                 항목 목록
  ./Scripts/pkgdump.py <scene.pkg> scene.json      항목 하나를 stdout으로
  ./Scripts/pkgdump.py <scene.pkg> --layers        씬 레이어 요약

라이브러리로 쓸 때:  from pkgdump import read_pkg   # {이름: bytes}
"""
import json
import struct
import sys


def read_pkg(path):
    """`{항목 이름: bytes}`. 이름이 겹치면 뒤엣것이 이긴다."""
    with open(path, "rb") as handle:
        data = handle.read()

    at = 0

    def int32():
        nonlocal at
        value, = struct.unpack_from("<i", data, at)
        at += 4
        return value

    def string():
        nonlocal at
        length = int32()
        if length < 0 or at + length > len(data):
            raise ValueError(f"문자열이 잘렸다 @{at}")
        text = data[at:at + length].decode("utf-8", "replace")
        at += length
        return text

    version = string()
    if not version.startswith("PKGV"):
        raise ValueError(f"PKGV로 시작하지 않는다: {version!r}")
    count = int32()
    if count < 0 or count > 1_000_000:
        raise ValueError(f"항목 수가 이상하다: {count}")

    table = []
    for _ in range(count):
        name = string()
        table.append((name, int32(), int32()))

    base = at
    out = {}
    for name, offset, length in table:
        start, end = base + offset, base + offset + length
        if offset < 0 or length < 0 or end > len(data):
            raise ValueError(f"항목이 파일 밖을 가리킨다: {name}")
        out[name] = data[start:end]
    return out


def scene_json(entries):
    """씬 정의가 든 최상위 JSON. 이름이 늘 `scene.json`인 것은 아니다."""
    if "scene.json" in entries:
        return json.loads(entries["scene.json"].decode("utf-8", "replace"))
    tops = [k for k in entries if k.endswith(".json") and "/" not in k]
    if not tops:
        raise ValueError("최상위 json이 없다")
    return json.loads(entries[tops[0]].decode("utf-8", "replace"))


def _describe(value):
    """`{"script": …, "user": …, "value": …}` 객체를 한 줄로 줄인다."""
    if isinstance(value, dict):
        parts = []
        if "script" in value:
            parts.append(f"script({len(value['script'].splitlines())}줄)")
        if value.get("user"):
            parts.append(f"user={value['user']}")
        if "value" in value:
            parts.append(str(value["value"])[:24])
        return " ".join(parts)
    return str(value)[:32]


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    entries = read_pkg(argv[0])
    if len(argv) == 1:
        for name in sorted(entries):
            print(f"{len(entries[name]):>10}  {name}")
        return 0
    if argv[1] == "--layers":
        for layer in scene_json(entries).get("objects", []):
            kind = next((k for k in ("image", "particle", "text", "sound", "model")
                         if k in layer), "?")
            print(f"{layer.get('id', '?'):>5} {kind:8} {str(layer.get('name', ''))[:28]:28} "
                  f"origin={_describe(layer.get('origin')):24} "
                  f"visible={_describe(layer.get('visible'))}")
        return 0
    name = argv[1]
    if name not in entries:
        print(f"그런 항목이 없다: {name}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(entries[name])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
