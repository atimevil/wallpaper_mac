import Accelerate
import AVFoundation
import Foundation
import ScreenCaptureKit

/// 시스템 소리를 듣고 주파수 스펙트럼을 만든다.
///
/// 창작마당의 오디오 비주얼라이저는 셰이더에서
/// `uniform float g_AudioSpectrum32Left[32]` 같은 배열을 읽는다. 그걸 채우려면
/// 지금 나고 있는 소리를 알아야 한다.
///
/// **기본은 꺼짐이다.** 배경화면은 늘 켜져 있는 프로그램이라, 사용자가 켜기 전에는
/// 아무것도 듣지 않는다. 켜면 macOS가 화면 녹화 권한을 한 번 묻는다 —
/// 시스템 오디오 캡처가 그 권한 아래 있다.
///
/// **소리를 저장하지도, 어디로 보내지도 않는다.** 들어온 표본은 곧바로 주파수
/// 크기로 바뀌어 그리는 데 쓰이고 버려진다.
@MainActor
final class AudioSpectrum: NSObject {
    nonisolated static let enabledKey = "wallflow.audioEnabled"

    /// 사용자가 오디오 반응을 켰는지. 기본은 꺼짐이다.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// WE의 주파수 해상도. 셰이더가 이 셋 중 하나를 골라 쓴다.
    nonisolated static let resolutions = [16, 32, 64]

    /// 대역별 크기(0~1). `[해상도: [왼쪽, 오른쪽]]`.
    private(set) var bands: [Int: (left: [Float], right: [Float])] = [:]

    private var stream: SCStream?
    private var isRunning = false
    /// FFT에 넣을 표본 수. 64대역을 만들려면 넉넉해야 한다.
    nonisolated static let fftSize = 1024
    private let queue = DispatchQueue(label: "dev.timevil.wallflow.audio")
    /// FFT 준비물은 오디오 큐에서만 쓴다. 메인 액터에 두면 콜백에서 못 만진다.
    nonisolated let analyzer = SpectrumAnalyzer()

    override init() {
        super.init()
        for resolution in Self.resolutions {
            bands[resolution] = (Array(repeating: 0, count: resolution),
                                 Array(repeating: 0, count: resolution))
        }
    }

    /// 캡처를 시작한다. 이미 돌고 있으면 아무 일도 없다.
    ///
    /// 권한이 없으면 macOS가 물어보고, 거절하면 조용히 실패한다 — 배경화면이
    /// 권한 창을 계속 띄우면 안 된다. 그 경우 스펙트럼은 0으로 남고
    /// 비주얼라이저는 잠잠한 모습이 된다.
    func start() {
        guard !isRunning, Self.isEnabled else { return }
        isRunning = true
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    self?.stopped("화면을 찾지 못했다")
                    return
                }
                // 그림은 필요 없다. 소리만 받는다 — 화면 픽셀을 읽지 않는다는 뜻이다.
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 44100
                configuration.channelCount = 2
                // 화면 캡처 자체는 최소로 둔다. 끌 수는 없어서 1x1로 줄인다.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                guard let self else { return }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(
                    self, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.started(stream)
            } catch {
                self?.stopped("\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        isRunning = false
        let stream = self.stream
        self.stream = nil
        for resolution in Self.resolutions {
            bands[resolution] = (Array(repeating: 0, count: resolution),
                                 Array(repeating: 0, count: resolution))
        }
        Task { try? await stream?.stopCapture() }
    }

    private func started(_ stream: SCStream) {
        guard isRunning else {
            Task { try? await stream.stopCapture() }
            return
        }
        self.stream = stream
        FileHandle.standardError.write(Data("시스템 소리 듣기를 시작했다\n".utf8))
    }

    private func stopped(_ reason: String) {
        isRunning = false
        FileHandle.standardError.write(Data(
            "시스템 소리를 듣지 못한다: \(reason)\n".utf8))
    }

}

/// FFT 준비물을 들고 표본을 대역 크기로 바꾼다.
///
/// 오디오 콜백은 메인이 아닌 큐에서 온다. 준비물을 메인 액터에 두면 거기서 만질 수
/// 없고, 콜백마다 새로 만들면 매번 할당이 돈다. 그래서 이 작은 객체가 따로 들고 있다.
/// **오디오 큐 하나에서만 쓴다** — 그 약속이 `@unchecked Sendable`의 근거다.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let setup: FFTSetup?
    /// 채널마다 최근 표본을 모아 둔다.
    ///
    /// ScreenCaptureKit은 한 번에 960개씩 준다 — FFT에 필요한 1024개보다 적다.
    /// 버퍼 하나만 보고 FFT를 걸면 표본이 모자라 아무 대역도 안 잡힌다
    /// (실물에서 스펙트럼이 계속 0이었다). 최근 것을 이어 붙여 쓴다.
    private var history: [[Float]] = [[], []]

    init() {
        setup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(AudioSpectrum.fftSize))), FFTRadix(kFFTRadix2))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// 한 채널의 표본을 대역 크기로 바꾼다.
    ///
    /// 사람이 소리를 듣는 방식이 로그라서, 대역도 로그로 나눈다 — 선형으로 나누면
    /// 낮은 음이 한 칸에 뭉치고 높은 음만 잔뜩 늘어서 막대가 오른쪽만 움직인다.
    /// 새로 들어온 표본을 채널마다 모아 둔다. **버퍼마다 한 번만** 부른다 —
    /// 해상도마다 부르면 같은 표본이 여러 번 쌓여 창이 어긋난다.
    func ingest(left: [Float], right: [Float]) {
        let fftSize = AudioSpectrum.fftSize
        for (channel, incoming) in [left, right].enumerated() {
            history[channel].append(contentsOf: incoming)
            if history[channel].count > fftSize {
                history[channel].removeFirst(history[channel].count - fftSize)
            }
        }
    }

    /// 모아 둔 창으로 대역 크기를 낸다.
    /// - Parameter channel: 0이 왼쪽, 1이 오른쪽.
    func spectrum(channel: Int, resolution: Int) -> [Float] {
        let fftSize = AudioSpectrum.fftSize
        guard let setup, resolution > 0, history.indices.contains(channel) else {
            return Array(repeating: 0, count: Swift.max(resolution, 0))
        }
        let samples = history[channel]
        // 아직 한 창을 채우지 못했다. 조용한 것으로 둔다 — 없는 표본을 0으로
        // 채워 FFT를 걸면 실제로 없는 저음이 잡힌다.
        guard samples.count == fftSize else {
            return Array(repeating: 0, count: resolution)
        }
        let half = fftSize / 2
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: half
                    ) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(
                    setup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var out = [Float](repeating: 0, count: resolution)
        for band in 0..<resolution {
            // 로그 간격. 첫 칸은 가장 낮은 몇 개의 빈만 본다.
            let lowRatio = pow(Double(half), Double(band) / Double(resolution)) - 1
            let highRatio = pow(Double(half), Double(band + 1) / Double(resolution)) - 1
            let low = Swift.min(half - 1, Swift.max(0, Int(lowRatio)))
            let high = Swift.min(half - 1, Swift.max(low + 1, Int(highRatio)))
            var sum: Float = 0
            for bin in low..<high { sum += magnitudes[bin] }
            let mean = sum / Float(high - low)
            // 크기를 0~1로 눌러 담는다. 그냥 쓰면 큰 소리에서 전부 1이 된다.
            out[band] = Swift.min(1, sqrt(mean) * 0.06)
        }
        return out
    }
}

extension AudioSpectrum: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio,
              let samples = Self.channels(of: sampleBuffer) else { return }
        analyzer.ingest(left: samples.left, right: samples.right)
        var computed: [Int: (left: [Float], right: [Float])] = [:]
        for resolution in Self.resolutions {
            computed[resolution] = (
                analyzer.spectrum(channel: 0, resolution: resolution),
                analyzer.spectrum(channel: 1, resolution: resolution))
        }
        let sampleCount = samples.left.count
        Task { @MainActor [weak self] in
            self?.bands = computed
            if ProcessInfo.processInfo.environment["WALLFLOW_AUDIO_DEBUG"] != nil {
                FileHandle.standardError.write(Data("AUDIO 표본 \(sampleCount)\n".utf8))
            }
            if ProcessInfo.processInfo.environment["WALLFLOW_AUDIO_DEBUG"] != nil,
               let bands = computed[32] {
                let peak = (bands.left + bands.right).max() ?? 0
                FileHandle.standardError.write(Data(
                    String(format: "AUDIO 최대 %.3f\n", peak).utf8))
            }
        }
    }

    /// 표본 버퍼에서 좌우 채널을 뽑는다. 모노면 같은 것을 양쪽에 쓴다.
    nonisolated static func channels(
        of buffer: CMSampleBuffer
    ) -> (left: [Float], right: [Float])? {
        guard let list = try? buffer.withAudioBufferList(body: {
            list, _ -> (left: [Float], right: [Float])? in
            guard let first = list.first, let data = first.mData else { return nil }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            let left = Array(UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: count))
            guard list.count > 1, let secondData = list[1].mData else { return (left, left) }
            let secondCount = Int(list[1].mDataByteSize) / MemoryLayout<Float>.size
            let right = Array(UnsafeBufferPointer(
                start: secondData.assumingMemoryBound(to: Float.self),
                count: Swift.max(0, secondCount)))
            return (left, right.isEmpty ? left : right)
        }) else { return nil }
        return list
    }
}
