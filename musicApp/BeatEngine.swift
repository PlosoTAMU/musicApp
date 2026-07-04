import Foundation

/// Predictive beat tracker.
///
/// The old visualizer *reacted*: energy spike → pulse → decay. Humans don't nod
/// reactively — they lock to the tactus and *predict*: the nod continues through
/// a quiet bar, lands on the beat rather than 50 ms after it, and doesn't
/// double-hit on off-beat transients. This engine supplies that:
///
///  - Tempo: autocorrelation of a ~6 s onset-strength envelope, weighted by a
///    log-Gaussian prior centred on 120 BPM (Ellis-style tactus preference),
///    with harmonic reinforcement so the beat wins over its subdivisions.
///    Tempo switches require 3 consecutive agreeing estimates (hysteresis).
///  - Phase: a PLL. Phase advances at the current tempo; onsets landing near a
///    predicted beat pull phase and period toward them, onsets elsewhere are
///    ignored (that's the "no double-hit" property). Confidence rises on
///    confirmed predictions and gates the output.
///  - Nod curve: sharp drop AT the beat, slow recovery, anticipatory lift into
///    the next beat — the kinematics of an actual head-nod. BPM above 150 folds
///    to half-time (people nod the tactus, not the hi-hat pattern).
///
/// Runs on the audio tap thread; no allocation after init.
final class BeatEngine {

    struct Output {
        var nod: Float          // 0-1 head-nod displacement, phase-driven
        var pulse: Float        // 0-1 per-beat pulse for bar modulation
        var confidence: Float   // 0-1 lock quality
        var bpm: Float
    }

    // Onset envelope ring (~6 s at ~43 fps)
    private let n = 256
    private var envelope: [Float]
    private var envIdx = 0
    private var filled = 0
    private var acfBuf: [Float]

    // Adaptive onset statistics (EMA mean + deviation)
    private var fluxMean: Float = 0.01
    private var fluxDev: Float = 0.01

    // PLL state
    private var periodS: Float = 0.5          // 120 BPM prior
    private var phase: Float = 0
    private var confidence: Float = 0
    private var beatParity = false            // for stable half-time folding

    // Tempo re-estimation
    private var framesSinceEstimate = 0
    private var candidateLag = 0
    private var candidateVotes = 0

    // Measured callback cadence — tap buffer sizes aren't guaranteed by AVAudioEngine.
    private var emaDt: Float = 1.0 / 43.0

    // Transient pulse (bars want real hits too, not only the phase clock)
    private var fluxPulse: Float = 0

    init() {
        envelope = [Float](repeating: 0, count: n)
        acfBuf = [Float](repeating: 0, count: n)
    }

    func reset() {
        for i in 0..<n { envelope[i] = 0 }
        envIdx = 0; filled = 0
        fluxMean = 0.01; fluxDev = 0.01
        periodS = 0.5; phase = 0; confidence = 0; beatParity = false
        framesSinceEstimate = 0; candidateLag = 0; candidateVotes = 0
        emaDt = 1.0 / 43.0
        fluxPulse = 0
    }

    /// - Parameters:
    ///   - onset: half-wave-rectified, kick-weighted log-spectral flux
    ///   - energyGate: 0-1 smoothed loudness (0 = silence → output fades)
    ///   - dt: seconds since the previous tap callback
    func process(onset: Float, energyGate: Float, dt: Float) -> Output {
        emaDt += (min(max(dt, 0.005), 0.1) - emaDt) * 0.1

        // Envelope + stats
        envelope[envIdx] = onset
        envIdx = (envIdx + 1) % n
        filled = min(filled + 1, n)
        fluxMean += (onset - fluxMean) * 0.03
        fluxDev += (abs(onset - fluxMean) - fluxDev) * 0.03

        // Phase advance
        phase += emaDt / max(periodS, 0.1)
        if phase >= 1 { phase -= 1; beatParity.toggle() }

        // Onset event → PLL correction
        let threshold = fluxMean + 1.5 * fluxDev
        if onset > threshold, filled > 40 {
            let strength = min(2, (onset - fluxMean) / max(fluxDev, 1e-4)) / 2
            // Signed distance from the nearest predicted beat, in beat units.
            let err = phase < 0.5 ? phase : phase - 1
            // Acquisition vs tracking: unlocked, capture almost any strong onset
            // (a dead-on tempo prior with an unlucky phase offset would otherwise
            // never converge — err sits outside a fixed window forever); locked,
            // tighten to ±0.22 so syncopation can't drag the phase.
            let win = 0.22 + 0.26 * max(0, 0.3 - confidence) / 0.3
            if abs(err) < win {
                // Onset confirms a predicted beat: pull phase onto it, and if
                // predictions run consistently early/late the period follows.
                phase -= err * (0.3 + 0.25 * strength)
                if phase < 0 { phase += 1; beatParity.toggle() }
                periodS *= 1 + err * 0.05
                confidence = min(1, confidence + (win - abs(err)) / win * 0.09 * (0.5 + strength))
            } else {
                // Energy between beats: syncopation is normal, so barely punish.
                confidence = max(0, confidence - 0.015)
            }
            fluxPulse = max(fluxPulse, strength)
        }

        // Idle decay: a lock that stops being confirmed fades in ~20 s, and
        // faster in silence.
        confidence *= energyGate > 0.1 ? 0.9992 : 0.996
        fluxPulse *= 0.72

        // Periodic tempo re-estimation
        framesSinceEstimate += 1
        if framesSinceEstimate >= 32, filled >= n / 2 {
            framesSinceEstimate = 0
            estimateTempo()
        }

        // Half/double-time folding for the nod (target 55-150 BPM window):
        // people nod the tactus, not the hi-hat pattern. beatParity keeps the
        // half-time fold from flipping which beat is the downbeat.
        var nodPhase = phase
        if 60 / periodS > 150 {
            nodPhase = (beatParity ? phase + 1 : phase) / 2
        } else if 60 / periodS < 55 {
            nodPhase = phase * 2 > 1 ? phase * 2 - 1 : phase * 2
        }

        // Nod kinematics: hit at the beat (sharp attack, ~exp recovery) plus an
        // anticipatory lift in the last quarter of the cycle. The discontinuity
        // at the wrap IS the thump.
        let gate = confidence * confidence * min(1, energyGate * 1.6)
        let attack = expf(-5.5 * nodPhase)
        let lift = smoothstep(0.72, 1.0, nodPhase) * 0.38
        let nod = (attack * 0.92 + lift) * gate

        // Bars: blend the phase clock with genuine transients so hits that the
        // tracker classifies as off-beat still flash (they're musical content),
        // just without moving the head.
        let phasePulse = expf(-8 * phase) * gate
        let pulse = max(phasePulse, fluxPulse * 0.75 * min(1, energyGate * 1.6))

        return Output(nod: min(1, nod), pulse: min(1, pulse),
                      confidence: confidence, bpm: 60 / periodS)
    }

    // MARK: - Tempo estimation

    private func estimateTempo() {
        // De-meaned copy in ring order (oldest → newest ordering is irrelevant
        // for autocorrelation lags).
        var mean: Float = 0
        for v in envelope { mean += v }
        mean /= Float(n)
        for i in 0..<n { acfBuf[i] = envelope[i] - mean }

        let minLag = max(4, Int(0.30 / emaDt))          // 200 BPM
        let maxLag = min(n / 2 - 1, Int(1.35 / emaDt))  // ~44 BPM
        guard maxLag > minLag + 2 else { return }

        func acf(_ lag: Int) -> Float {
            var s: Float = 0
            for i in 0..<(n - lag) { s += acfBuf[i] * acfBuf[i + lag] }
            return max(0, s)
        }

        var bestLag = 0
        var bestScore: Float = 0
        var sumScore: Float = 0
        for lag in minLag...maxLag {
            let period = Float(lag) * emaDt
            // Log-Gaussian tactus prior centred on 0.5 s (120 BPM).
            let prior = expf(-0.5 * powf(log2f(period / 0.5) / 0.9, 2))
            var score = acf(lag) * prior
            if lag * 2 <= maxLag { score += 0.45 * acf(lag * 2) * prior }  // harmonic support
            sumScore += score
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 0, sumScore > 0 else { return }
        let salience = bestScore / (sumScore / Float(maxLag - minLag + 1) + 1e-6)
        guard salience > 1.8 else { return }            // flat ACF = no rhythm; keep coasting

        let measured = Float(bestLag) * emaDt
        if abs(measured - periodS) / periodS < 0.12 {
            // Agrees with the lock → refine.
            periodS = periodS * 0.85 + measured * 0.15
            candidateVotes = 0
        } else if abs(bestLag - candidateLag) <= 1 {
            // Disagrees, but consistently → after 3 votes, switch tempo.
            candidateVotes += 1
            if candidateVotes >= 3 {
                periodS = measured
                confidence *= 0.5                        // relock phase via PLL
                candidateVotes = 0
            }
        } else {
            candidateLag = bestLag
            candidateVotes = 1
        }
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
