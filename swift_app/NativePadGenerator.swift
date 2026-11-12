import Foundation

/// Gerador nativo em Swift de Pads contínuos de ambiência (12 tonalidades).
/// Gera drones quentes e suaves de sustentação para transições ao vivo.
final class NativePadGenerator {
    static let shared = NativePadGenerator()
    
    private let sampleRate: Double = 44100.0
    private var cache = [String: [Float]]()
    
    // Frequências fundamentais das 12 notas (Oitava 2 e 3)
    private let notesFreq: [String: Double] = [
        "C": 65.41, "C#": 69.30, "Db": 69.30,
        "D": 73.42, "D#": 77.78, "Eb": 77.78,
        "E": 82.41, "F": 87.31,
        "F#": 92.50, "Gb": 92.50,
        "G": 98.00, "G#": 103.83, "Ab": 103.83,
        "A": 110.00, "A#": 116.54, "Bb": 116.54,
        "B": 123.47
    ]
    
    func getPadChunk(key: String, durationSec: Double = 10.0) -> [Float] {
        let cleanKey = key.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = notesFreq.keys.contains(cleanKey) ? cleanKey : "D"
        
        if let cached = cache[resolvedKey] {
            return cached
        }
        
        let baseF = notesFreq[resolvedKey] ?? 73.42
        let nSamples = Int(sampleRate * durationSec)
        var buffer = [Float](repeating: 0, count: nSamples)
        
        let fRoot1 = baseF
        let fRoot2 = baseF * 2.0
        let fFifth = baseF * 1.5
        let fNinth = baseF * 2.25
        let fOct3 = baseF * 4.0
        
        let twoPi = 2.0 * Double.pi
        
        for i in 0..<nSamples {
            let t = Double(i) / sampleRate
            
            // Síntese aditiva com leve desafinação analógica
            var s = 0.40 * sin(twoPi * fRoot1 * t)
            s += 0.30 * sin(twoPi * (fRoot2 + 0.15) * t)
            s += 0.25 * sin(twoPi * (fFifth - 0.12) * t)
            s += 0.15 * sin(twoPi * (fNinth + 0.20) * t)
            s += 0.08 * sin(twoPi * fOct3 * t)
            
            // LFO lento de respiração (0.12 Hz)
            let lfo = 0.85 + 0.15 * sin(twoPi * 0.12 * t)
            s *= lfo
            
            buffer[i] = Float(s)
        }
        
        // Suavização das bordas para looping perfeito (Fade in/out de 0.5s)
        let fadeLen = Int(sampleRate * 0.5)
        for i in 0..<fadeLen {
            let factor = Float(i) / Float(fadeLen)
            let endIdx = nSamples - fadeLen + i
            let blended = buffer[i] * factor + buffer[endIdx] * (1.0 - factor)
            buffer[i] = blended
        }
        
        // Normalização
        var maxVal: Float = 0.001
        for val in buffer {
            let absV = abs(val)
            if absV > maxVal { maxVal = absV }
        }
        for i in 0..<nSamples {
            buffer[i] = (buffer[i] / maxVal) * 0.95
        }
        
        cache[resolvedKey] = buffer
        return buffer
    }
}
