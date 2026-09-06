import Foundation

/// 창작마당 스크립트가 있다고 가정하는 전역들.
///
/// 씬 스크립트는 Wallpaper Engine의 SceneScript 런타임 안에서 돌기 때문에,
/// `Vec3`나 `engine` 같은 것들이 이미 있다고 보고 그냥 쓴다. 우리 `JSContext`에
/// 그게 없으면 **스크립트 본문 평가가 통째로 실패해** 레이어가 저장된 값으로
/// 굳어 버린다. 흰 상자나 검은 상자가 배경화면에 남는 원인이 이것이다.
///
/// 보유한 실물 씬 145개 스크립트를 세어 보면 `new Vec3`가 120번, `engine.*`가
/// 80번 나온다. 이름과 의미는 공식 SceneScript 레퍼런스를 따랐다:
/// <https://docs.wallpaperengine.io/en/scene/scenescript/reference.html>
///
/// **없는 것은 없는 대로 둔다.** 오디오 버퍼처럼 우리가 정말 못 주는 것은
/// null을 돌려준다 — 그럴듯한 가짜 값을 주면 스크립트가 잘못된 그림을 그린다.
public enum SceneScriptRuntime {
    /// 스크립트가 물어보는 환경 값들. 렌더러가 아는 것을 넘겨준다.
    public struct Environment: Equatable, Sendable {
        /// 배경화면이 그려지는 화면 크기(픽셀).
        public var screenWidth: Double
        public var screenHeight: Double
        /// 씬이 만들어질 때의 직교 공간 크기.
        public var canvasWidth: Double
        public var canvasHeight: Double

        public init(screenWidth: Double = 1920, screenHeight: Double = 1080,
                    canvasWidth: Double = 1920, canvasHeight: Double = 1080) {
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.canvasWidth = canvasWidth
            self.canvasHeight = canvasHeight
        }
    }

    /// `Vec2`/`Vec3`. 변환 메서드는 **새 객체를 돌려주고 원본을 두는 것**이
    /// 문서에 명시된 동작이다("returns result as a new object").
    /// 제자리에서 바꾸면 `let b = a.add(v)` 뒤에 `a`까지 바뀌어 조용히 어긋난다.
    static let vectors = """
    function __wfNum(v) { return typeof v === 'number' ? v : Number(v); }

    function Vec2(x, y) {
        if (x === undefined) { this.x = 0; this.y = 0; }
        else if (typeof x === 'string') {
            var p = x.trim().split(/\\s+/).map(Number);
            this.x = p[0] || 0; this.y = (p.length > 1 ? p[1] : p[0]) || 0;
        } else if (typeof x === 'object' && x !== null) {
            this.x = __wfNum(x.x) || 0; this.y = __wfNum(x.y) || 0;
        } else if (y === undefined) { this.x = __wfNum(x); this.y = __wfNum(x); }
        else { this.x = __wfNum(x); this.y = __wfNum(y); }
    }

    function Vec3(x, y, z) {
        if (x === undefined) { this.x = 0; this.y = 0; this.z = 0; }
        else if (typeof x === 'string') {
            var p = x.trim().split(/\\s+/).map(Number);
            this.x = p[0] || 0;
            this.y = (p.length > 1 ? p[1] : p[0]) || 0;
            this.z = (p.length > 2 ? p[2] : (p.length > 1 ? 0 : p[0])) || 0;
        } else if (typeof x === 'object' && x !== null) {
            this.x = __wfNum(x.x) || 0;
            this.y = __wfNum(x.y) || 0;
            this.z = x.z === undefined ? 0 : (__wfNum(x.z) || 0);
        } else if (y === undefined) {
            this.x = __wfNum(x); this.y = __wfNum(x); this.z = __wfNum(x);
        } else {
            this.x = __wfNum(x); this.y = __wfNum(y);
            this.z = z === undefined ? 0 : __wfNum(z);
        }
    }

    // 인자는 수·Vec2·Vec3 아무거나 온다. 성분별 연산으로 맞춘다.
    function __wfV3(v) { return (v instanceof Vec3) ? v : new Vec3(v); }

    Vec3.fromSpherical = function (r, theta, phi) {
        return new Vec3(r * Math.sin(theta) * Math.cos(phi),
                        r * Math.sin(theta) * Math.sin(phi),
                        r * Math.cos(theta));
    };

    Vec3.prototype.equals = function (o) {
        o = __wfV3(o); return this.x === o.x && this.y === o.y && this.z === o.z;
    };
    Vec3.prototype.add = function (v) {
        v = __wfV3(v); return new Vec3(this.x + v.x, this.y + v.y, this.z + v.z);
    };
    Vec3.prototype.subtract = function (v) {
        v = __wfV3(v); return new Vec3(this.x - v.x, this.y - v.y, this.z - v.z);
    };
    Vec3.prototype.multiply = function (v) {
        v = __wfV3(v); return new Vec3(this.x * v.x, this.y * v.y, this.z * v.z);
    };
    Vec3.prototype.divide = function (v) {
        v = __wfV3(v); return new Vec3(this.x / v.x, this.y / v.y, this.z / v.z);
    };
    Vec3.prototype.negate = function () { return new Vec3(-this.x, -this.y, -this.z); };
    Vec3.prototype.copy = function () { return new Vec3(this.x, this.y, this.z); };
    Vec3.prototype.lengthSqr = function () {
        return this.x * this.x + this.y * this.y + this.z * this.z;
    };
    Vec3.prototype.length = function () { return Math.sqrt(this.lengthSqr()); };
    Vec3.prototype.distanceSqr = function (o) { return __wfV3(o).subtract(this).lengthSqr(); };
    Vec3.prototype.distance = function (o) { return __wfV3(o).subtract(this).length(); };
    Vec3.prototype.normalize = function () {
        var l = this.length();
        return l === 0 ? new Vec3(0, 0, 0) : new Vec3(this.x / l, this.y / l, this.z / l);
    };
    Vec3.prototype.isFinite = function () {
        return isFinite(this.x) && isFinite(this.y) && isFinite(this.z);
    };
    Vec3.prototype.dot = function (v) {
        v = __wfV3(v); return this.x * v.x + this.y * v.y + this.z * v.z;
    };
    Vec3.prototype.cross = function (v) {
        v = __wfV3(v);
        return new Vec3(this.y * v.z - this.z * v.y,
                        this.z * v.x - this.x * v.z,
                        this.x * v.y - this.y * v.x);
    };
    Vec3.prototype.project = function (v) {
        v = __wfV3(v); return v.multiply(this.dot(v) / v.lengthSqr());
    };
    Vec3.prototype.reflect = function (n) {
        n = __wfV3(n); return this.subtract(n.multiply(2 * this.dot(n)));
    };
    Vec3.prototype.refract = function (n, eta) {
        n = __wfV3(n);
        var d = this.dot(n);
        var k = 1 - eta * eta * (1 - d * d);
        if (k < 0) { return new Vec3(0, 0, 0); }
        return this.multiply(eta).subtract(n.multiply(eta * d + Math.sqrt(k)));
    };
    Vec3.prototype.angleBetween = function (v) {
        v = __wfV3(v);
        var d = this.length() * v.length();
        return d === 0 ? 0 : Math.acos(Math.min(1, Math.max(-1, this.dot(v) / d)));
    };
    Vec3.prototype.toSpherical = function () {
        var r = this.length();
        return new Vec3(r, r === 0 ? 0 : Math.acos(this.z / r), Math.atan2(this.y, this.x));
    };
    Vec3.prototype.mix = function (o, a) {
        o = __wfV3(o); return this.add(o.subtract(this).multiply(a));
    };
    Vec3.prototype.min = function (v) {
        v = __wfV3(v);
        return new Vec3(Math.min(this.x, v.x), Math.min(this.y, v.y), Math.min(this.z, v.z));
    };
    Vec3.prototype.max = function (v) {
        v = __wfV3(v);
        return new Vec3(Math.max(this.x, v.x), Math.max(this.y, v.y), Math.max(this.z, v.z));
    };
    Vec3.prototype.clamp = function (lo, hi) { return this.max(lo).min(hi); };
    Vec3.prototype.abs = function () {
        return new Vec3(Math.abs(this.x), Math.abs(this.y), Math.abs(this.z));
    };
    Vec3.prototype.sign = function () {
        return new Vec3(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z));
    };
    Vec3.prototype.round = function () {
        return new Vec3(Math.round(this.x), Math.round(this.y), Math.round(this.z));
    };
    Vec3.prototype.floor = function () {
        return new Vec3(Math.floor(this.x), Math.floor(this.y), Math.floor(this.z));
    };
    Vec3.prototype.ceil = function () {
        return new Vec3(Math.ceil(this.x), Math.ceil(this.y), Math.ceil(this.z));
    };
    Vec3.prototype.fract = function () { return this.subtract(this.floor()); };
    Vec3.prototype.mod = function (v) {
        v = __wfV3(v);
        return new Vec3(this.x % v.x, this.y % v.y, this.z % v.z);
    };
    Vec3.prototype.step = function (e) {
        e = __wfV3(e);
        return new Vec3(this.x < e.x ? 0 : 1, this.y < e.y ? 0 : 1, this.z < e.z ? 0 : 1);
    };
    Vec3.prototype.smoothStep = function (lo, hi) {
        var t = this.subtract(lo).divide(__wfV3(hi).subtract(lo)).clamp(0, 1);
        return t.multiply(t).multiply(new Vec3(3, 3, 3).subtract(t.multiply(2)));
    };
    Vec3.prototype.toString = function () {
        return this.x + ' ' + this.y + ' ' + this.z;
    };

    // Vec2는 화면·캔버스 크기를 돌려줄 때 쓰인다. 성분 접근이 대부분이라
    // 최소한만 둔다 — 안 쓰는 메서드를 짐작해 넣으면 틀린 채로 남는다.
    Vec2.prototype.copy = function () { return new Vec2(this.x, this.y); };
    Vec2.prototype.length = function () {
        return Math.sqrt(this.x * this.x + this.y * this.y);
    };
    Vec2.prototype.add = function (v) {
        v = new Vec2(v); return new Vec2(this.x + v.x, this.y + v.y);
    };
    Vec2.prototype.subtract = function (v) {
        v = new Vec2(v); return new Vec2(this.x - v.x, this.y - v.y);
    };
    Vec2.prototype.multiply = function (v) {
        v = new Vec2(v); return new Vec2(this.x * v.x, this.y * v.y);
    };
    Vec2.prototype.toString = function () { return this.x + ' ' + this.y; };
    """

    /// `engine` 전역. 이름과 의미는 IEngine 레퍼런스를 따랐다.
    ///
    /// `frametime`과 `runtime`은 호출할 때마다 Swift 쪽에서 채운다.
    /// 못 주는 것(오디오 버퍼)은 null을 돌려준다 — 가짜 스펙트럼을 주면
    /// 비주얼라이저가 실제 소리와 무관하게 움직이는, 더 나쁜 거짓말이 된다.
    static func engine(_ env: Environment) -> String {
        """
        var engine = {
            frametime: 0,
            runtime: 0,
            screenResolution: new Vec2(\(env.screenWidth), \(env.screenHeight)),
            canvasSize: new Vec2(\(env.canvasWidth), \(env.canvasHeight)),
            userProperties: {},
            timeOfDay: 0,
            AUDIO_RESOLUTION_16: 16,
            AUDIO_RESOLUTION_32: 32,
            AUDIO_RESOLUTION_64: 64,
            isDesktopDevice: function () { return true; },
            isMobileDevice: function () { return false; },
            isWallpaper: function () { return true; },
            isScreensaver: function () { return false; },
            isPortrait: function () { return \(env.screenHeight > env.screenWidth); },
            isLandscape: function () { return \(env.screenWidth >= env.screenHeight); },
            isRunningInEditor: function () { return false; },
            openUserShortcut: function () { return false; },
            registerAudioBuffers: function () { return null; },
            registerAsset: function () { return null; },
            setTimeout: function () { return function () {}; },
            setInterval: function () { return function () {}; }
        };
        // 씬 안의 스크립트끼리 값을 주고받는 통로. 실물에서 `shared.xxx`를 읽는
        // 스크립트 4개가 이 변수가 없어 통째로 죽었다. 우리는 스크립트를 레이어마다
        // 따로 돌리므로 실제로 공유되지는 않는다 — 읽으면 undefined다.
        // 없는 값을 지어내는 것보다는 낫다.
        var shared = {};
        var Shared = shared;

        var console = console || {};
        console.log = console.log || function () {};
        console.error = console.error || function () {};
        console.warn = console.warn || function () {};
        console.info = console.info || function () {};
        """
    }
}
