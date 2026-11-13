import AVFoundation

/// Sintesi vocale italiana locale (AVSpeechSynthesizer) scritta su file: i segmenti restano su disco,
/// si riascoltano offline e non si rigenerano a ogni avvio.
final class SintetizzatoreFile: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var completamenti: [ObjectIdentifier: (Error?) -> Void] = [:]
    private let lucchettoMappa = NSLock()

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    /// Migliore voce italiana installata: Premium > Avanzata > standard. Si sceglie ascoltando (Impostazioni).
    static func voceItaliana(identificativo: String? = nil) -> AVSpeechSynthesisVoice? {
        if let id = identificativo, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let it = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
        return it.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "it-IT")
    }

    static var vociItaliane: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Scrive `testo` in `url` (.m4a AAC; se il codificatore non è disponibile, .caf PCM accanto).
    /// Restituisce URL effettivo e durata in secondi. Chiamate sequenziali (una alla volta).
    func scrivi(_ testo: String, voce: AVSpeechSynthesisVoice?, url: URL) async throws -> (URL, Double) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, Double), Error>) in
            let utt = AVSpeechUtterance(string: testo)
            utt.voice = voce
            utt.rate = AVSpeechUtteranceDefaultSpeechRate
            utt.prefersAssistiveTechnologySettings = false
            var file: AVAudioFile?
            var destinazione = url
            var frame: AVAudioFramePosition = 0
            var frequenza = 22050.0
            var chiuso = false
            let lucchetto = NSRecursiveLock()
            let chiave = ObjectIdentifier(utt)

            func chiudi(_ errore: Error?) {
                lucchetto.lock(); defer { lucchetto.unlock() }
                guard !chiuso else { return }
                chiuso = true
                file = nil   // chiude e finalizza il file
                self.lucchettoMappa.lock(); self.completamenti[chiave] = nil; self.lucchettoMappa.unlock()
                if let e = errore { cont.resume(throwing: e) }
                else if frame == 0 { cont.resume(throwing: NSError(domain: "Voce", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nessun audio prodotto"])) }
                else { cont.resume(returning: (destinazione, Double(frame) / frequenza)) }
            }
            self.lucchettoMappa.lock(); self.completamenti[chiave] = { e in chiudi(e) }; self.lucchettoMappa.unlock()

            self.synth.write(utt) { buffer in
                lucchetto.lock(); defer { lucchetto.unlock() }
                guard !chiuso, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { chiudi(nil); return }
                do {
                    if file == nil {
                        frequenza = pcm.format.sampleRate
                        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: pcm.format.sampleRate,
                                                  AVNumberOfChannelsKey: Int(pcm.format.channelCount), AVEncoderBitRateKey: 32000]
                        do {
                            file = try AVAudioFile(forWriting: url, settings: aac, commonFormat: pcm.format.commonFormat,
                                                   interleaved: pcm.format.isInterleaved)
                        } catch {
                            destinazione = url.deletingPathExtension().appendingPathExtension("caf")
                            file = try AVAudioFile(forWriting: destinazione, settings: pcm.format.settings,
                                                   commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                        }
                    }
                    try file?.write(from: pcm)
                    frame += AVAudioFramePosition(pcm.frameLength)
                } catch {
                    chiudi(error)
                }
            }
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        // Alcune versioni di iOS non inviano il buffer finale vuoto: la fine dell'enunciato chiude il file.
        let chiave = ObjectIdentifier(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.completa(chiave, nil) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        completa(ObjectIdentifier(u), CancellationError())
    }

    private func completa(_ chiave: ObjectIdentifier, _ errore: Error?) {
        lucchettoMappa.lock(); let c = completamenti[chiave]; lucchettoMappa.unlock()
        c?(errore)
    }
}
