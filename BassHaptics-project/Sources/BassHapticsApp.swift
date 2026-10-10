import SwiftUI
import AVFoundation
import CoreHaptics
import AudioToolbox
import UIKit

// MARK: - Simple biquad low-pass filter (isolates the bass)

struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    init(cutoff: Double, sampleRate: Double, q: Double = 0.7071) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = ((1 - cosw) / 2) / a0
        b1 = (1 - cosw) / a0
        b2 = ((1 - cosw) / 2) / a0
        a1 = (-2 * cosw) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: - Bass analyzer + haptics

final class BassEngine: ObservableObject {
    @Published var level: Float = 0            // 0...1 smoothed bass level
    @Published var history: [Float] = Array(repeating: 0, count: 150)
    @Published var running = false
    @Published var sensitivity: Float = 1.0
    @Published var cutoff: Double = 150        // Hz

    private let audio = AVAudioEngine()
    private var filterA: Biquad?
    private var filterB: Biquad?
    private var haptic: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    private var smoothed: Float = 0
    private var peak: Float = 0.001            // adaptive gain
    private var inBackground = false
    private var lastBuzz = Date.distantPast

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = true
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = false
            self?.startHaptics()
        }
    }

    // MARK: Start / stop

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else { return }
                self?.begin()
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .measurement turns off auto gain / voice processing so bass isn't filtered out.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)

            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            let sr = format.sampleRate
            filterA = Biquad(cutoff: cutoff, sampleRate: sr)
            filterB = Biquad(cutoff: cutoff, sampleRate: sr) // cascaded = steeper roll-off

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            audio.prepare()
            try audio.start()
            startHaptics()
            running = true
        } catch {
            print("Audio start failed:", error)
        }
    }

    func stop() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        try? player?.stop(atTime: CHHapticTimeImmediate)
        haptic?.stop()
        running = false
    }

    // MARK: Haptics (Core Haptics works in foreground)

    private func startHaptics() {
        guard running || audio.isRunning,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if haptic == nil {
                haptic = try CHHapticEngine()
                haptic?.isAutoShutdownEnabled = false
                haptic?.resetHandler = { [weak self] in self?.startHaptics() }
            }
            try haptic?.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)],
                                      relativeTime: 0, duration: 30)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            player = try haptic?.makeAdvancedPlayer(with: pattern)
            player?.loopEnabled = true
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Haptics failed:", error)
        }
    }

    private func updateHaptic(_ v: Float) {
        let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                         value: v, relativeTime: 0)
        try? player?.sendParameters([p], atTime: CHHapticTimeImmediate)
    }

    // MARK: Analysis

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], var a = filterA, var b = filterB else { return }
        let n = Int(buffer.frameLength)
        var sum = 0.0
        for i in 0..<n {
            let y = b.process(a.process(Double(data[i])))
            sum += y * y
        }
        filterA = a; filterB = b
        let rms = Float(sqrt(sum / Double(max(n, 1))))

        // Adaptive normalization: fast attack, slow release on the peak reference.
        peak = max(rms, peak * 0.9995)
        var norm = min(1, (rms / max(peak, 0.0005)) * sensitivity)
        norm = norm * norm                       // expo curve: quiet bass stays quiet
        if peak < 0.0008 { norm = 0 }            // noise gate

        // Smooth: fast up, slower down.
        smoothed = norm > smoothed ? norm : smoothed * 0.85 + norm * 0.15

        let value = smoothed
        DispatchQueue.main.async {
            self.level = value
            self.history.removeFirst()
            self.history.append(value)
        }

        if inBackground {
            // Core Haptics is suspended in the background; fall back to the
            // fixed system vibration (no intensity control), throttled.
            if value > 0.45, Date().timeIntervalSince(lastBuzz) > 0.35 {
                lastBuzz = Date()
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        } else {
            updateHaptic(value)
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var engine = BassEngine()

    var body: some View {
        VStack(spacing: 24) {
            Text("Bass Haptics").font(.largeTitle.bold())

            Canvas { ctx, size in
                let h = engine.history
                let w = size.width / CGFloat(h.count)
                for (i, v) in h.enumerated() {
                    let bar = max(2, CGFloat(v) * size.height)
                    let rect = CGRect(x: CGFloat(i) * w, y: size.height - bar,
                                      width: w - 1, height: bar)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(.pink.opacity(0.35 + Double(v) * 0.65)))
                }
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            ProgressView(value: engine.level).tint(.pink)

            VStack(alignment: .leading) {
                Text("Sensitivity")
                Slider(value: $engine.sensitivity, in: 0.3...2.5)
                Text("Bass cutoff: \(Int(engine.cutoff)) Hz")
                Slider(value: $engine.cutoff, in: 60...250, step: 10)
                    .disabled(engine.running)
            }

            Button(engine.running ? "Stop" : "Start") {
                engine.running ? engine.stop() : engine.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.running ? .red : .pink)
            .controlSize(.large)

            Text("Keep the phone on your lap or couch, not on the speaker, or its own vibration will feed back into the mic.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}

@main
struct BassHapticsApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
