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
        var timeSignature: String // Fórmula de compasso detectada ou confirmada (ex: "6/8", "4/4", "3/4")
    }

    // MARK: - API

    /// `left` é o canal L (Click + Guia); `right` opcional é o canal R (Playback/Instrumentos para análise estrutural).
    /// O completion é chamado numa fila de background; devolve nil se não achar click ou voz.
    func analyze(
        left: [Float],
        right: [Float] = [],
        sampleRate: Double,
        bpmHint: Double,
        timeSignature: String,
        completion: @escaping (Result?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.analyzeSync(
                left: left,
                right: right,
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

    private func analyzeSync(left: [Float], right: [Float] = [], sr: Double, bpmHint: Double, timeSignature: String) -> Result? {
        guard sr > 8000, left.count > Int(sr * 20.0) else { return nil }
        let totalDuration = Double(left.count) / sr

        var num = 4
        var den = 4
        let parts = timeSignature.split(separator: "/")
        if let first = parts.first, let n = Int(first), n > 0 { num = n }
        if parts.count > 1, let d = Int(parts[1]), d > 0 { den = d }
        let hasHint = bpmHint >= 30.0

        // 1. Cliques: passa-altas 700 Hz + envelope RMS de 1 ms com distância adaptativa
        let hop1 = max(1, Int(sr * 0.001))
        let dt1 = Double(hop1) / sr
        let hp = applyFilters(left, [Biquad(highPass: 700.0, sampleRate: sr)])
        let env = rmsEnvelope(hp, hop: hop1)
        let thr = max(Float(0.02), 0.12 * percentile(env, 0.995))
        let minD = max(1, Int(0.065 / dt1))
        let peakIdx = pickPeaks(env, threshold: thr, minDistance: minD)
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
            if d > 0.07 && d < 1.8 { diffs.append(d) }
        }
        guard diffs.count >= 16 else { return nil }
        let binW = 0.002
        let lo = 0.07
        var hist = [Int](repeating: 0, count: Int((1.8 - lo) / binW) + 3)
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
            if abs((times[i] - times[i - 1]) - per) < 0.08 * per {
                run += 1
                if run > bestRun { bestRun = run; bestStart = i - run }
            } else {
                run = 0
            }
        }
        guard bestRun >= 8 else { return nil }
        var t0 = times[bestStart]

        // 4. Ajuste por mínimos quadrados adaptativo, expandindo a cobertura a cada iteração
        var good = [Bool](repeating: false, count: times.count)
        var goodCount = 0
        let resThreshold = max(0.015, min(0.035, 0.15 * per))
        for _ in 0..<16 {
            var mask = [Bool](repeating: false, count: times.count)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, c = 0.0
            for i in 0..<times.count {
                let k = ((times[i] - t0) / per).rounded()
                let res = times[i] - (t0 + k * per)
                if abs(res) < resThreshold {
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

        // Primeira sequência estável de cliques consecutivos (ignora ruído inicial)
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
        if runStartIdx < 0 {
            runStartIdx = times.indices.first { good[$0] } ?? 0
        }

        // 5. Detecção de Fórmula de Compasso por Periodicidade de Acentos
        let candidatesTS = [3, 4, 6, 8, 12, 16]
        var bestCandidateTS = 4
        var bestContrastTS: Float = 0
        for k in candidatesTS {
            var phases = [[Float]](repeating: [], count: k)
            var sampleCount = 0
            for i in runStartIdx..<times.count where good[i] {
                let ph = ((kIdx[i] % k) + k) % k
                phases[ph].append(heights[i])
                sampleCount += 1
                if sampleCount >= 300 { break }
            }
            let medians = phases.map { ph -> Float in
                guard !ph.isEmpty else { return 0 }
                let s = ph.sorted()
                return s[s.count / 2]
            }
            guard let maxMed = medians.max() else { continue }
            let otherMeds = medians.filter { $0 < maxMed }
            let avgOther = otherMeds.isEmpty ? 1.0 : (otherMeds.reduce(0, +) / Float(otherMeds.count))
            let ratio = maxMed / max(0.001, avgOther)
            if ratio > bestContrastTS {
                bestContrastTS = ratio
                bestCandidateTS = k
            }
        }

        var detectedTs = "4/4"
        if (bestCandidateTS == 12 || bestCandidateTS == 6) && bestContrastTS >= 1.15 {
            detectedTs = "6/8"
        } else if bestCandidateTS == 3 && bestContrastTS >= 1.15 {
            detectedTs = "3/4"
        }

        let finalTs: String
        if timeSignature == "4/4" && detectedTs != "4/4" {
            finalTs = detectedTs
        } else if !timeSignature.isEmpty {
            finalTs = timeSignature
        } else {
            finalTs = detectedTs
        }

        let tsParts = finalTs.split(separator: "/")
        if let first = tsParts.first, let n = Int(first), n > 0 { num = n }
        if tsParts.count > 1, let d = Int(tsParts[1]), d > 0 { den = d }

        var clicksPerBar = bestCandidateTS
        if hasHint {
            let beats = Double(num) * (4.0 / Double(den))
            let expectedBarSec = (60.0 / bpmHint) * beats
            let expectedClicks = Int(round(expectedBarSec / per))
            if expectedClicks > 0 && abs(Double(expectedClicks) * per - expectedBarSec) < 0.15 * expectedBarSec {
                clicksPerBar = expectedClicks
            }
        }
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

        // 6. Voz: apaga os cliques do L com janela proporcional, passa-faixa 200–3500 Hz, energia adaptativa
        var cleaned = left
        let zb = Int(0.006 * sr)
        let za = Int(min(0.045, per * 0.35) * sr)
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
        let p50 = percentile(envS, 0.50)
        let p95 = percentile(envS, 0.95)
        let thrV = max(Float(0.015), max(p50 * 2.5, 0.14 * p95))

        var phrases: [Phrase] = []
        let hang = Int(min(0.35, max(0.18, per * 0.8)) / dtV)
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
                if Double(e - i) * dtV >= 0.22 {
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
        if hasHint {
            let beats = Double(num) * (4.0 / Double(den))
            let barHint = (60.0 / bpmHint) * beats
            if starts.count >= 6 {
                let rHint = resultant(starts, bar: barHint, anchor: anchor, num: num)
                let rClick = resultant(starts, bar: barClick, anchor: anchor, num: num)
                if rHint > rClick + 0.02 { bar = barHint }
                print(String(format: "[NativeCueDetector] alinhamento da voz: click %.3f, BPM do arquivo %.3f", rClick, rHint))
            } else if abs(barHint - barClick) < 0.25 * barClick {
                bar = barHint
            }
        }

        // 8. Contagem protegida (máximo 2 compassos)
        let countInBars = min(2, max(0, Int(floor((firstClickTime - anchor) / bar + 0.1))))
        let countInEnd = anchor + Double(countInBars) * bar
        let hasCountIn = countInBars >= 1

        // 9. Transcrição e Filtragem com Whisper e Dinâmica
        var rawCandidates: [(cand: Candidate, label: Label?, isDynamic: Bool)] = []
        for p in phrases {
            if p.start < countInEnd - 0.2 { continue }
            let j = Int(ceil((p.start - 0.15 - anchor) / bar))
            let tc = anchor + Double(j) * bar
            if tc >= totalDuration - 1.0 { continue }
            
            // Recorta áudio limpo da frase falada (-0.25s a +0.35s)
            let a = max(0, Int((p.start - 0.25) * sr))
            let b = min(cleaned.count, Int((p.end + 0.35) * sr))
            let slice = cleaned[a..<b]
            
            var label: Label? = nil
            var isDynamic = false
            
            if let whisperRes = NativeCueDetector.transcribeWithWhisper(slice: slice, sr: sr) {
                isDynamic = whisperRes.isDynamic
                label = whisperRes.label
            }
            
            // Se for aviso de dinâmica ("cresce", "pausa", "segura"), IGNORA como corte de seção!
            if isDynamic {
                print(String(format: "[NativeCueDetector] Aviso de dinâmica ignorado como corte de bloco em %.2fs", tc))
                continue
            }
            
            let cand = Candidate(time: tc, start: p.start, end: p.end)
            rawCandidates.append((cand: cand, label: label, isDynamic: false))
        }
        
        // Unificação de seções adjacentes e garantia de duração mínima (mínimo 1.45 compassos)
        var candidates: [Candidate] = []
        var labels: [Label?] = []
        for item in rawCandidates {
            if let last = candidates.last, abs(item.cand.time - last.time) < 1.45 * bar {
                candidates[candidates.count - 1].end = max(last.end, item.cand.end)
                if labels.last == nil && item.label != nil {
                    labels[labels.count - 1] = item.label
                }
                continue
            }
            candidates.append(item.cand)
            labels.append(item.label)
        }
        guard !candidates.isEmpty else { return nil }

        // Se alguma seção ficou sem label pelo Whisper, tenta o fallback com Apple Speech
        for i in 0..<candidates.count {
            if labels[i] == nil {
                let a = max(0, Int((candidates[i].start - 0.25) * sr))
                let b = min(cleaned.count, Int((candidates[i].end + 0.35) * sr))
                if a < b {
                    labels[i] = recognizeSingleLabel(slice: cleaned[a..<b], sr: sr)
                }
            }
        }

        var cues: [CueSection] = []
        func add(_ name: String, _ time: Double, _ color: String) {
            let t = max(0.0, (time * 100.0).rounded() / 100.0)
            let barNo = Double(Int(((time - anchor) / bar).rounded()) + 1)
            cues.append(CueSection(id: "cue_\(cues.count)", name: name, time: t, bar: barNo, color: color, waveform: nil))
        }
        if hasCountIn { add("Count-In", 0.0, "#64748b") }
        let introStart = hasCountIn ? countInEnd : 0.0
        let hasIntro = candidates[0].time > introStart + 0.5 * bar
        if hasIntro { add("Intro", introStart, "#38bdf8") }

        // Mede energia RMS das faixas para classificar musicalmente trechos não nomeados por voz
        let refTrack = !right.isEmpty ? right : cleaned
        var cueBoundaries = [0.0]
        if hasCountIn && candidates[0].time != countInEnd { cueBoundaries.append(countInEnd) }
        for c in candidates { cueBoundaries.append(c.time) }
        cueBoundaries.append(totalDuration)
        cueBoundaries = Array(Set(cueBoundaries)).sorted()

        var sectionEnergies: [Double] = []
        for idx in 0..<(cueBoundaries.count - 1) {
            let sF = Int(cueBoundaries[idx] * sr)
            let eF = min(refTrack.count, Int(cueBoundaries[idx + 1] * sr))
            var sum = 0.0
            for k in sF..<eF { sum += Double(refTrack[k] * refTrack[k]) }
            sectionEnergies.append((sum / Double(max(1, eF - sF))).squareRoot())
        }
        let sortedRMS = sectionEnergies.sorted()
        let medRMS = sortedRMS.isEmpty ? 0.05 : sortedRMS[sortedRMS.count / 2]

        var verseNum = 1
        var chorusNum = 0
        var bridgeFound = false
        var named = 0
        let totalCands = candidates.count

        for (idx, cand) in candidates.enumerated() {
            if let lab = labels[idx] {
                named += 1
                var name = lab.base
                if lab.base == "Verse" {
                    name = "Verse \(lab.number ?? verseNum)"
                    verseNum += 1
                } else if lab.base == "Chorus" {
                    chorusNum += 1
                    name = "Chorus" + (lab.number.map { " \($0)" } ?? (chorusNum > 1 ? " \(chorusNum)" : ""))
                } else if let n = lab.number {
                    name = "\(lab.base) \(n)"
                }
                add(name, cand.time, lab.color)
            } else {
                // Classificação Estrutural Musical Inteligente
                let secIdx = min(sectionEnergies.count - 1, idx + (hasCountIn ? 1 : 0) + (hasIntro ? 1 : 0))
                let rms = sectionEnergies[secIdx]
                let isLast = (idx == totalCands - 1)

                let name: String
                let color: String
                if isLast && cand.time > totalDuration - (bar * 8) {
                    name = "Ending"
                    color = "#64748b"
                } else if rms > medRMS * 1.20 {
                    if chorusNum >= 2 && !bridgeFound && Double(idx) > Double(totalCands) * 0.45 {
                        name = "Bridge"
                        color = "#f97316"
                        bridgeFound = true
                    } else {
                        chorusNum += 1
                        name = "Chorus" + (chorusNum > 1 ? " \(chorusNum)" : "")
                        color = "#ef4444"
                    }
                } else if rms > medRMS * 1.05 && idx + 1 < totalCands && sectionEnergies[min(sectionEnergies.count - 1, secIdx + 1)] > medRMS * 1.20 {
                    name = "Pre-Chorus"
                    color = "#ec4899"
                } else if chorusNum >= 1 && !bridgeFound && Double(idx) > Double(totalCands) * 0.50 {
                    name = "Bridge"
                    color = "#f97316"
                    bridgeFound = true
                } else if rms < medRMS * 0.70 && Double(idx) > Double(totalCands) * 0.25 {
                    name = "Instrumental"
                    color = "#10b981"
                } else {
                    name = "Verse \(verseNum)"
                    color = "#a855f7"
                    verseNum += 1
                }
                add(name, cand.time, color)
            }
        }
        if let f = cues.first, f.time > 0.01 { cues[0].time = 0.0 }

        let gridBpm = 60.0 * Double(num) * (4.0 / Double(den)) / bar
        let clickBpm = 60.0 * Double(num) * (4.0 / Double(den)) / barClick
        print(String(format: "[NativeCueDetector] %ld seções (%ld via fala, %ld estrutural) | compasso %@ | grade %.3f BPM | click %.3f BPM",
                     cues.count, named, cues.count - named, finalTs, gridBpm, clickBpm))
        return Result(cues: cues, gridBpm: gridBpm, clickBpm: clickBpm, namedCount: named, timeSignature: finalTs)
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

    // MARK: - Whisper.cpp Nativo & Reconhecimento de Voz

    private static let dynamicKeywords: [String] = [
        "cresce", "crescendo", "cresceu", "sobe", "subindo", "subiu", "pressao", "pressão",
        "pausa", "pause", "ausa", "parada", "para", "parou",
        "segura", "segurou", "segure",
        "corta", "cortou", "corte",
        "suave", "abaixa", "desce", "cai", "caindo", "diminui",
        "todos", "toda banda", "juntos",
        "bumbo", "baixo", "só piano", "piano", "violao", "violão",
        "convencao", "convenção",
        "prepara", "atencao", "atenção"
    ]

    private static func findWhisperCli() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let candidates: [String?] = [
            Bundle.main.resourcePath.map { "\($0)/whisper-cli" },
            Bundle.main.bundlePath + "/Contents/Resources/whisper-cli",
            Bundle.main.bundlePath + "/Contents/MacOS/whisper-cli",
            appSupport.appendingPathComponent("VSControl/whisper-cli").path,
            "/Users/samysglauber/Documents/AbletonTracks/swift_app/whisper/whisper-cli",
            "/tmp/whisper.cpp/main"
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findWhisperModel() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportModel = appSupport.appendingPathComponent("VSControl/models/ggml-tiny.bin").path
        let candidates: [String?] = [
            Bundle.main.resourcePath.map { "\($0)/models/ggml-tiny.bin" },
            Bundle.main.bundlePath + "/Contents/Resources/models/ggml-tiny.bin",
            appSupportModel,
            "/Users/samysglauber/Documents/AbletonTracks/swift_app/whisper/models/ggml-tiny.bin",
            "/tmp/whisper.cpp/models/ggml-tiny.bin"
        ]
        if let found = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        
        let targetDir = appSupport.appendingPathComponent("VSControl/models")
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetPath = targetDir.appendingPathComponent("ggml-tiny.bin").path
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!
        let sem = DispatchSemaphore(value: 0)
        var success = false
        print("[NativeCueDetector] Baixando modelo Whisper Tiny para \(targetPath)...")
        let task = URLSession.shared.downloadTask(with: url) { tempFile, _, err in
            if let tempFile = tempFile, err == nil {
                try? FileManager.default.removeItem(atPath: targetPath)
                do {
                    try FileManager.default.moveItem(at: tempFile, to: URL(fileURLWithPath: targetPath))
                    success = true
                } catch {
                    print("[NativeCueDetector] Erro ao mover modelo: \(error)")
                }
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 60)
        return success ? targetPath : nil
    }

    private static func writeWav16k(samples: ArraySlice<Float>, srcSR: Double, to url: URL) -> Bool {
        let targetSR: Double = 16000.0
        let count = samples.count
        guard count > 0 else { return false }
        
        let targetCount = Int(Double(count) * targetSR / srcSR)
        guard targetCount > 0 else { return false }
        
        var outSamples = [Int16](repeating: 0, count: targetCount)
        samples.withUnsafeBufferPointer { srcPtr in
            guard let base = srcPtr.baseAddress else { return }
            for i in 0..<targetCount {
                let srcIdx = min(count - 1, Int(Double(i) * srcSR / targetSR))
                let s = max(-1.0, min(1.0, base[srcIdx]))
                outSamples[i] = Int16(s * 32767.0)
            }
        }
        
        let dataSize = Int32(targetCount * 2)
        let chunkSize = 36 + dataSize
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        var cs = chunkSize; header.append(Data(bytes: &cs, count: 4))
        header.append("WAVEfmt ".data(using: .ascii)!)
        var sub1: Int32 = 16; header.append(Data(bytes: &sub1, count: 4))
        var fmt: Int16 = 1; header.append(Data(bytes: &fmt, count: 2))
        var ch: Int16 = 1; header.append(Data(bytes: &ch, count: 2))
        var sr = Int32(targetSR); header.append(Data(bytes: &sr, count: 4))
        var br = Int32(targetSR * 2); header.append(Data(bytes: &br, count: 4))
        var ba: Int16 = 2; header.append(Data(bytes: &ba, count: 2))
        var bps: Int16 = 16; header.append(Data(bytes: &bps, count: 2))
        header.append("data".data(using: .ascii)!)
        var ds = dataSize; header.append(Data(bytes: &ds, count: 4))
        
        var fileData = header
        outSamples.withUnsafeBufferPointer { p in
            fileData.append(Data(buffer: p))
        }
        
        do {
            try fileData.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func transcribeWithWhisper(slice: ArraySlice<Float>, sr: Double) -> (text: String, isDynamic: Bool, label: Label?)? {
        guard let whisperBin = findWhisperCli(),
              let modelPath = findWhisperModel() else {
            return nil
        }
        
        let tempWav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempWav) }
        
        guard writeWav16k(samples: slice, srcSR: sr, to: tempWav) else { return nil }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: whisperBin)
        proc.arguments = [
            "-m", modelPath,
            "-f", tempWav.path,
            "-l", "pt",
            "-nt",
            "-t", "4",
            "--prompt", "intro verso refrão ponte pré-refrão instrumental solo final cresce pausa segura"
        ]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let rawText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty else { return nil }
            
            let normalized = rawText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            
            // 1. Verifica se é aviso de dinâmica (NÃO GERA CORTE)
            for dyn in dynamicKeywords {
                if normalized.contains(dyn) {
                    return (text: rawText, isDynamic: true, label: nil)
                }
            }
            
            // 2. Verifica se é seção estrutural
            if let label = mapLabel(rawText) {
                return (text: rawText, isDynamic: false, label: label)
            }
            
            return (text: rawText, isDynamic: false, label: nil)
        } catch {
            return nil
        }
    }

    private static let vocabulary: [String] = [
        "intro", "verse", "chorus", "pre-chorus", "bridge", "instrumental", "solo", "interlude", "ending", "outro", "tag",
        "verso", "estrofe", "refrão", "pré-refrão", "ponte", "interlúdio", "final", "fim", "coda", "entrou", "berço", "fonte",
        "one", "two", "three", "four", "um", "dois", "três", "quatro", "primeiro", "segundo", "terceiro"
    ]

    private func ensureSpeechAuthorization() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
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
            _ = sem.wait(timeout: .now() + 10)
            return ok.value
        default:
            return false
        }
    }

    private func recognizeSingleLabel(slice: ArraySlice<Float>, sr: Double) -> Label? {
        guard ensureSpeechAuthorization() else { return nil }
        let recognizers: [SFSpeechRecognizer] = ["pt-BR", "en-US"].compactMap { id in
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)),
                  r.isAvailable else { return nil }
            r.queue = OperationQueue()
            return r
        }
        var bestLabel: Label? = nil
        var bestConf: Float = -1
        for rec in recognizers {
            if let (text, conf) = transcribe(slice, sr: sr, recognizer: rec),
               let lab = NativeCueDetector.mapLabel(text), conf > bestConf {
                bestLabel = lab
                bestConf = conf
            }
        }
        return bestLabel
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
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
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
        if sem.wait(timeout: .now() + 8) == .timedOut { task.cancel() }
        return out.value
    }

    /// Converte o texto reconhecido num nome de seção conhecido.
    private static func mapLabel(_ text: String) -> Label? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let joined = tokens.joined()

        let numberWords: [String: Int] = [
            "1": 1, "um": 1, "uma": 1, "one": 1, "primeiro": 1,
            "2": 2, "dois": 2, "duas": 2, "two": 2, "segundo": 2,
            "3": 3, "tres": 3, "three": 3, "terceiro": 3,
            "4": 4, "quatro": 4, "four": 4, "quarto": 4
        ]
        var number: Int? = nil
        for t in tokens { if let n = numberWords[t] { number = n; break } }

        func has(_ words: [String]) -> Bool { tokens.contains { words.contains($0) } }

        if joined.contains("prechorus") || joined.contains("prerefrao") || joined.contains("precoro") || joined.contains("posse") || joined.contains("posrefrao") || joined.contains("derrefram") || joined.contains("pre") || joined.contains("pré") {
            return Label(base: "Pre-Chorus", color: "#ec4899", number: nil)
        }
        if has(["chorus", "refrao", "refrão", "refra", "coro", "corus", "frao", "frão"]) || joined.contains("refrao") || joined.contains("refrão") {
            return Label(base: "Chorus", color: "#ef4444", number: number)
        }
        if has(["verse", "verso", "versos", "berco", "berço", "derso", "estrofe", "strofe", "primeiro", "segundo", "terceiro"]) || joined.contains("verso") {
            return Label(base: "Verse", color: "#a855f7", number: number)
        }
        if has(["bridge", "ponte", "fonte"]) || joined.contains("ponte") {
            return Label(base: "Bridge", color: "#f97316", number: number)
        }
        if has(["intro", "entrou", "introducao", "introdução"]) || joined.contains("intro") {
            return Label(base: "Intro", color: "#38bdf8", number: nil)
        }
        if has(["instrumental", "instru", "solo", "interlude", "interludio", "interlúdio", "interloujo"]) || joined.contains("interlude") || joined.contains("instrumental") {
            return Label(base: "Instrumental", color: "#10b981", number: nil)
        }
        if has(["ending", "end", "final", "fim", "outro", "termina", "coda"]) || joined.contains("final") {
            return Label(base: "Ending", color: "#64748b", number: nil)
        }
        if has(["tag", "ministracao", "ministração", "espontaneo", "espontâneo"]) || joined.contains("tag") {
            return Label(base: "Tag", color: "#eab308", number: nil)
        }
        return nil
    }
}
