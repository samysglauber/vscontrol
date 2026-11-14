import Foundation
import Accelerate
import AVFoundation
import Speech

/// Detecção nativa de seções para VS com click + voz guia no canal L.
///
/// Substitui o script Python `detect_cues.py`. Tudo roda offline:
///   1. Acha os cliques no canal L (passa-altas + envelope) e ajusta uma grade regular a eles.
///   2. Descobre o tempo 1 de cada compasso pelo acento do click.
///   3. Apaga os cliques do canal L e isola as frases de voz por energia.
///   4. Escolhe a grade de compassos (do click ou do BPM do arquivo) pela que melhor
///      alinha as entradas da voz guia aos tempos do compasso.
///   5. Cada frase vira uma seção, no primeiro tempo 1 depois do início da palavra.
///   6. Reconhece o nome falado (Speech, on-device, pt-BR e en-US). Sem permissão ou sem
///      modelo, as seções saem como "Section N", já nos tempos certos.
final class NativeCueDetector {
    static let shared = NativeCueDetector()
    private init() {}

    struct Result {
        var cues: [CueSection]
        var gridBpm: Double      // BPM da grade usada para ajustar os cortes
        var clickBpm: Double     // BPM medido no click
        var namedCount: Int      // quantas seções tiveram o nome reconhecido
    }

    // MARK: - API

    /// `left` é o canal L já decodificado (o engine já o tem em memória).
    /// O completion é chamado numa fila de background; devolve nil se não achar click ou voz.
    func analyze(
        left: [Float],
        sampleRate: Double,
        bpmHint: Double,
        timeSignature: String,
        completion: @escaping (Result?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.analyzeSync(
                left: left,
                sr: sampleRate,
                bpmHint: bpmHint,
                timeSignature: timeSignature
            )
            completion(result)
        }
    }

    // MARK: - Tipos internos

    private struct Phrase {
        var start: Double
        var end: Double
    }

    private struct Candidate {
        var time: Double     // tempo do tempo 1 onde a seção começa
        var start: Double    // início da voz
        var end: Double      // fim da voz
    }

    private struct Label {
        var base: String
        var color: String
        var number: Int?
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        init(highPass fc: Double, sampleRate sr: Double) {
            let w0 = 2.0 * Double.pi * fc / sr
            let alpha = sin(w0) / (2.0 * 0.70710678)
            let c = cos(w0)
            let a0 = 1.0 + alpha
            b0 = ((1.0 + c) / 2.0) / a0
            b1 = (-(1.0 + c)) / a0
            b2 = b0
            a1 = (-2.0 * c) / a0
            a2 = (1.0 - alpha) / a0
        }

        init(lowPass fc: Double, sampleRate sr: Double) {
            let w0 = 2.0 * Double.pi * fc / sr
            let alpha = sin(w0) / (2.0 * 0.70710678)
            let c = cos(w0)
            let a0 = 1.0 + alpha
            b0 = ((1.0 - c) / 2.0) / a0
            b1 = (1.0 - c) / a0
            b2 = b0
            a1 = (-2.0 * c) / a0
            a2 = (1.0 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    // MARK: - Pipeline

    private func analyzeSync(left: [Float], sr: Double, bpmHint: Double, timeSignature: String) -> Result? {
        guard sr > 8000, left.count > Int(sr * 20.0) else { return nil }
        let totalDuration = Double(left.count) / sr

        var num = 4
        if let first = timeSignature.split(separator: "/").first, let n = Int(first), n > 0 { num = n }
        let hasHint = bpmHint >= 30.0

        // 1. Cliques: passa-altas 700 Hz + envelope RMS de 1 ms
        let hop1 = max(1, Int(sr * 0.001))
        let dt1 = Double(hop1) / sr
        let hp = applyFilters(left, [Biquad(highPass: 700.0, sampleRate: sr)])
        let env = rmsEnvelope(hp, hop: hop1)
        let thr = max(Float(0.02), 0.12 * percentile(env, 0.995))
        let peakIdx = pickPeaks(env, threshold: thr, minDistance: Int(0.3 / dt1))
        guard peakIdx.count >= 24 else {
            print("[NativeCueDetector] poucos picos de click (\(peakIdx.count)); sem faixa de click no L?")
            return nil
        }
        let times = peakIdx.map { Double($0) * dt1 }
        let heights = peakIdx.map { env[$0] }

        // 2. Período do click: moda dos intervalos entre picos
        var diffs: [Double] = []
        for i in 1..<times.count {
            let d = times[i] - times[i - 1]
            if d > 0.12 && d < 1.5 { diffs.append(d) }
        }
        guard diffs.count >= 16 else { return nil }
        let binW = 0.002
        let lo = 0.12
        var hist = [Int](repeating: 0, count: Int((1.5 - lo) / binW) + 3)
        for d in diffs { hist[Int((d - lo) / binW)] += 1 }
        var bestBin = 1
        var bestScore = -1
        for b in 1..<(hist.count - 1) {
            let s = hist[b - 1] + hist[b] + hist[b + 1]
            if s > bestScore { bestScore = s; bestBin = b }
        }
        let center = lo + (Double(bestBin) + 0.5) * binW
        let near = diffs.filter { abs($0 - center) < 0.008 }.sorted()
        guard !near.isEmpty else { return nil }
        var per = near[near.count / 2]

        // 3. Semente: maior sequência de picos espaçados pelo período
        var bestRun = 0
        var bestStart = 0
        var run = 0
        for i in 1..<times.count {
            if abs((times[i] - times[i - 1]) - per) < 0.06 * per {
                run += 1
                if run > bestRun { bestRun = run; bestStart = i - run }
            } else {
                run = 0
            }
        }
        guard bestRun >= 8 else { return nil }
        var t0 = times[bestStart]

        // 4. Ajuste por mínimos quadrados, expandindo a cobertura a cada iteração
        var good = [Bool](repeating: false, count: times.count)
        var goodCount = 0
        for _ in 0..<16 {
            var mask = [Bool](repeating: false, count: times.count)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, c = 0.0
            for i in 0..<times.count {
                let k = ((times[i] - t0) / per).rounded()
                let res = times[i] - (t0 + k * per)
                if abs(res) < 0.02 {
                    mask[i] = true
                    sx += k; sy += times[i]; sxx += k * k; sxy += k * times[i]; c += 1
                }
            }
            guard c >= 8 else { break }
            let denom = c * sxx - sx * sx
            guard abs(denom) > 1e-9 else { break }
            let slope = (c * sxy - sx * sy) / denom
            let intercept = (sy - slope * sx) / c
            let done = (Int(c) == goodCount) && abs(slope - per) < 1e-7
            t0 = intercept
            per = slope
            goodCount = Int(c)
            good = mask
            if done { break }
        }
        guard goodCount >= 16, per > 0.05 else { return nil }
        let kIdx = times.map { Int((($0 - t0) / per).rounded()) }

        // Primeira sequência estável de 8 cliques consecutivos (ignora ruído da contagem falada)
        var runStartIdx = -1
        var consecutive = 0
        var prevK = Int.min
        var candidateStart = 0
        for i in 0..<times.count where good[i] {
            if prevK != Int.min && kIdx[i] == prevK + 1 {
                consecutive += 1
            } else {
                consecutive = 1
                candidateStart = i
            }
            prevK = kIdx[i]
            if consecutive >= 8 { runStartIdx = candidateStart; break }
        }
        guard runStartIdx >= 0 else { return nil }

        // 5. Cliques por compasso e fase do acento (tempo 1)
        let clicksPerBar = hasHint
            ? max(1, Int((Double(num) * 60.0 / bpmHint / per).rounded()))
            : num
        var perPhase = [[Float]](repeating: [], count: clicksPerBar)
        var used = 0
        for i in runStartIdx..<times.count where good[i] {
            let ph = ((kIdx[i] % clicksPerBar) + clicksPerBar) % clicksPerBar
            perPhase[ph].append(heights[i])
            used += 1
            if used >= 300 { break }
        }
        let meds = perPhase.map { median($0) }
        var accentPhase = 0
        for p in 0..<meds.count where meds[p] > meds[accentPhase] { accentPhase = p }
        var others = meds
        others.remove(at: accentPhase)
        let contrast = meds[accentPhase] / max(median(others), 1e-6)
        if contrast < 1.15 {
            // sem acento claro: assume que o primeiro click estável é o tempo 1
            accentPhase = ((kIdx[runStartIdx] % clicksPerBar) + clicksPerBar) % clicksPerBar
        }

        var tAccEarly = times[runStartIdx]
        for i in runStartIdx..<times.count where good[i] {
            let ph = ((kIdx[i] % clicksPerBar) + clicksPerBar) % clicksPerBar
            if ph == accentPhase { tAccEarly = times[i]; break }
        }
        let barClick = Double(clicksPerBar) * per
        let anchor = tAccEarly - floor((tAccEarly + 0.25) / barClick) * barClick
        let firstClickTime = times[runStartIdx]

        // 6. Voz: apaga os cliques do L, passa-faixa 200–3500 Hz, energia de 20 ms
        var cleaned = left
        let zb = Int(0.005 * sr)
        let za = Int(0.060 * sr)
        for t in times {
            let c = Int(t * sr)
            let a = max(0, c - zb)
            let b = min(cleaned.count, c + za)
            if a < b { for j in a..<b { cleaned[j] = 0 } }
        }
        let band = applyFilters(cleaned, [
            Biquad(highPass: 200.0, sampleRate: sr),
            Biquad(lowPass: 3500.0, sampleRate: sr)
        ])
        let hopV = max(1, Int(sr * 0.02))
        let dtV = Double(hopV) / sr
        let envV = rmsEnvelope(band, hop: hopV)
        var envS = envV
        if envV.count > 1 {
            for i in 1..<envV.count {
                envS[i] = ((envV[i] * envV[i] + envV[i - 1] * envV[i - 1]) / 2.0).squareRoot()
            }
        }
        let thrV = max(Float(0.02), 0.12 * percentile(envS, 0.98))

        var phrases: [Phrase] = []
        let hang = Int((0.4 / dtV).rounded())
        var i = 0
        while i < envS.count {
            if envS[i] > thrV {
                var last = i
                var j = i
                while j < envS.count && j - last <= hang {
                    if envS[j] > thrV { last = j }
                    j += 1
                }
                let e = last + 1
                if Double(e - i) * dtV >= 0.25 {
                    phrases.append(Phrase(start: Double(i) * dtV, end: Double(e) * dtV))
                }
                i = e
            } else {
                i += 1
            }
        }
        guard !phrases.isEmpty else {
            print("[NativeCueDetector] nenhuma frase de voz encontrada")
            return nil
        }

        // 7. Grade de compassos: click medido ou BPM do arquivo? A voz guia decide.
        var bar = barClick
        let starts = phrases.map { $0.start }.filter { $0 > anchor + 1.2 * barClick }
        if hasHint && starts.count >= 6 {
            let barHint = Double(num) * 60.0 / bpmHint
            let rHint = resultant(starts, bar: barHint, anchor: anchor, num: num)
            let rClick = resultant(starts, bar: barClick, anchor: anchor, num: num)
            if rHint > rClick + 0.02 { bar = barHint }
            print(String(format: "[NativeCueDetector] alinhamento da voz: click %.3f, BPM do arquivo %.3f", rClick, rHint))
        }

        // 8. Contagem e seções
        let countInBars = max(0, Int(floor((firstClickTime - anchor) / bar + 0.1)))
        let countInEnd = anchor + Double(countInBars) * bar
        let hasCountIn = countInBars >= 1

        var candidates: [Candidate] = []
        for p in phrases {
            if p.start < countInEnd - 0.2 { continue }
            let j = Int(ceil((p.start - 0.15 - anchor) / bar))
            let tc = anchor + Double(j) * bar
            if tc >= totalDuration - 1.0 { continue }
            if let last = candidates.last, abs(last.time - tc) < 0.5 * bar {
                candidates[candidates.count - 1].end = p.end     // palavra composta ("pré" + "refrão")
                continue
            }
            candidates.append(Candidate(time: tc, start: p.start, end: p.end))
        }
        guard !candidates.isEmpty else { return nil }

        // 9. Nomes falados
        let labels = recognizeLabels(candidates: candidates, samples: cleaned, sr: sr)

        var cues: [CueSection] = []
        func add(_ name: String, _ time: Double, _ color: String) {
            let t = max(0.0, (time * 100.0).rounded() / 100.0)
            let barNo = Double(Int(((time - anchor) / bar).rounded()) + 1)
            cues.append(CueSection(id: "cue_\(cues.count)", name: name, time: t, bar: barNo, color: color, waveform: nil))
        }
        if hasCountIn { add("Count-In", 0.0, "#64748b") }
        let introStart = hasCountIn ? countInEnd : 0.0
        if candidates[0].time > introStart + 0.5 * bar { add("Intro", introStart, "#38bdf8") }

        var verseCount = 0
        var named = 0
        for (idx, cand) in candidates.enumerated() {
            if let lab = labels[idx] {
                named += 1
                var name = lab.base
                if lab.base == "Verse" {
                    verseCount += 1
                    name = "Verse \(lab.number ?? verseCount)"
                } else if let n = lab.number {
                    name = "\(lab.base) \(n)"
                }
                add(name, cand.time, lab.color)
            } else {
                add("Section \(idx + 1)", cand.time, "#94a3b8")
            }
        }
        if let f = cues.first, f.time > 0.01 { cues[0].time = 0.0 }

        let gridBpm = 60.0 * Double(num) / bar
        let clickBpm = 60.0 * Double(num) / barClick
        print(String(format: "[NativeCueDetector] %ld seções (%ld com nome) | grade %.3f BPM | click %.3f BPM",
                     cues.count, named, gridBpm, clickBpm))
        return Result(cues: cues, gridBpm: gridBpm, clickBpm: clickBpm, namedCount: named)
    }

    // MARK: - Sinal

    private func applyFilters(_ x: [Float], _ filters: [Biquad]) -> [Float] {
        var fs = filters
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var v = Double(x[i])
            for j in 0..<fs.count { v = fs[j].process(v) }
            out[i] = Float(v)
        }
        return out
    }

    private func rmsEnvelope(_ x: [Float], hop: Int) -> [Float] {
        let n = x.count / hop
        var env = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for i in 0..<n {
                var r: Float = 0
                vDSP_rmsqv(base + i * hop, 1, &r, vDSP_Length(hop))
                env[i] = r
            }
        }
        return env
    }

    private func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let idx = min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))
        return s[idx]
    }

    private func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    private func pickPeaks(_ env: [Float], threshold: Float, minDistance: Int) -> [Int] {
        var peaks: [Int] = []
        guard env.count > 2 else { return peaks }
        for i in 1..<(env.count - 1) {
            let v = env[i]
            guard v >= threshold, v >= env[i - 1], v > env[i + 1] else { continue }
            if let last = peaks.last, i - last < minDistance {
                if v > env[last] { peaks[peaks.count - 1] = i }
            } else {
                peaks.append(i)
            }
        }
        return peaks
    }

    /// Comprimento do vetor resultante (0…1) das fases das entradas dentro do tempo.
    /// Perto de 1 = as palavras caem sempre no mesmo ponto do tempo, ou seja, a grade está certa.
    private func resultant(_ starts: [Double], bar: Double, anchor: Double, num: Int) -> Double {
        guard !starts.isEmpty else { return 0 }
        let beat = bar / Double(num)
        var cx = 0.0
        var cy = 0.0
        for s in starts {
            let ph = ((s - anchor) / beat).truncatingRemainder(dividingBy: 1.0)
            let a = 2.0 * Double.pi * ph
            cx += cos(a)
            cy += sin(a)
        }
        return (cx * cx + cy * cy).squareRoot() / Double(starts.count)
    }

    // MARK: - Reconhecimento de fala (on-device)

    private static let vocabulary: [String] = [
        "intro", "verse", "chorus", "pre-chorus", "bridge", "instrumental", "solo", "interlude", "ending", "outro", "tag",
        "verso", "estrofe", "refrão", "pré-refrão", "ponte", "interlúdio", "final", "fim", "coda",
        "one", "two", "three", "four", "um", "dois", "três", "quatro"
    ]

    private func ensureSpeechAuthorization() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            print("[NativeCueDetector] NSSpeechRecognitionUsageDescription ausente no Info.plist; seções ficarão sem nome.")
            return false
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            let ok = Box<Bool>(false)
            SFSpeechRecognizer.requestAuthorization { status in
                ok.value = (status == .authorized)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)
            return ok.value
        default:
            return false
        }
    }

    private func recognizeLabels(candidates: [Candidate], samples: [Float], sr: Double) -> [Label?] {
        var result = [Label?](repeating: nil, count: candidates.count)
        guard ensureSpeechAuthorization() else { return result }

        let recognizers: [SFSpeechRecognizer] = ["pt-BR", "en-US"].compactMap { id in
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)),
                  r.isAvailable, r.supportsOnDeviceRecognition else { return nil }
            r.queue = OperationQueue()
            return r
        }
        guard !recognizers.isEmpty else {
            print("[NativeCueDetector] sem reconhecedor on-device disponível (pt-BR/en-US)")
            return result
        }

        for (idx, cand) in candidates.enumerated() {
            let a = max(0, Int((cand.start - 0.25) * sr))
            let b = min(samples.count, Int((cand.end + 0.35) * sr))
            guard a < b else { continue }
            let slice = samples[a..<b]

            var bestLabel: Label? = nil
            var bestConf: Float = -1
            for rec in recognizers {
                if let (text, conf) = transcribe(slice, sr: sr, recognizer: rec),
                   let lab = NativeCueDetector.mapLabel(text), conf > bestConf {
                    bestLabel = lab
                    bestConf = conf
                }
            }
            result[idx] = bestLabel
        }
        return result
    }

    private func transcribe(_ samples: ArraySlice<Float>, sr: Double, recognizer: SFSpeechRecognizer) -> (String, Float)? {
        let count = samples.count
        guard count > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let dst = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(dst, base, count * MemoryLayout<Float>.size) }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = NativeCueDetector.vocabulary
        request.append(buffer)
        request.endAudio()

        let sem = DispatchSemaphore(value: 0)
        let out = Box<(String, Float)?>(nil)
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let r = result, r.isFinal {
                let segs = r.bestTranscription.segments
                let conf: Float = segs.isEmpty ? 0 : segs.map { $0.confidence }.reduce(0, +) / Float(segs.count)
                out.value = (r.bestTranscription.formattedString, conf)
                sem.signal()
            } else if error != nil {
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + 12) == .timedOut { task.cancel() }
        return out.value
    }

    /// Converte o texto reconhecido num nome de seção conhecido.
    private static func mapLabel(_ text: String) -> Label? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let joined = tokens.joined()

        let numberWords: [String: Int] = [
            "1": 1, "um": 1, "uma": 1, "one": 1,
            "2": 2, "dois": 2, "duas": 2, "two": 2,
            "3": 3, "tres": 3, "three": 3,
            "4": 4, "quatro": 4, "four": 4
        ]
        var number: Int? = nil
        for t in tokens { if let n = numberWords[t] { number = n; break } }

        func has(_ words: [String]) -> Bool { tokens.contains { words.contains($0) } }

        if joined.contains("prechorus") || joined.contains("prerefrao") || joined.contains("precoro") {
            return Label(base: "Pre-Chorus", color: "#ec4899", number: nil)
        }
        if has(["chorus", "refrao", "coro", "corus"]) { return Label(base: "Chorus", color: "#ef4444", number: number) }
        if has(["verse", "verso", "versos", "estrofe", "strofe"]) { return Label(base: "Verse", color: "#a855f7", number: number) }
        if has(["bridge", "ponte"]) { return Label(base: "Bridge", color: "#f97316", number: number) }
        if has(["intro", "introducao"]) { return Label(base: "Intro", color: "#38bdf8", number: nil) }
        if has(["instrumental", "solo", "interlude", "interludio"]) { return Label(base: "Instrumental", color: "#10b981", number: nil) }
        if has(["ending", "end", "final", "fim", "outro", "coda"]) { return Label(base: "Ending", color: "#64748b", number: nil) }
        if has(["tag"]) { return Label(base: "Tag", color: "#eab308", number: nil) }
        return nil
    }
}
