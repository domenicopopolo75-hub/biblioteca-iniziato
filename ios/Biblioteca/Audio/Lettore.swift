import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Misure della prova d'ascolto (dossier §12): tempo al primo audio, latenze per blocco,
/// riserva minima, interruzioni. Esportabili in JSON.
struct Metriche: Codable {
    struct Interruzione: Codable { var inizio: Date; var durata: Double; var causa: String }
    var libro = ""
    var motoreTraduzione = ""
    var voce = ""
    var velocita = 1.0
    var richiesta = Date()
    var primoAudioSecondi: Double?
    var latenzeTraduzione: [Double] = []   // secondi per lotto di paragrafi
    var latenzeSintesi: [Double] = []      // secondi reali per segmento
    var durateSegmenti: [Double] = []      // secondi di audio per segmento
    var riservaMinima: Double?
    var interruzioni: [Interruzione] = []
    var secondiAscoltati = 0.0

    static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    /// Rapporto produzione/consumo: > 1 vuol dire che la riserva cresce alla velocità scelta.
    var rapportoProduzione: Double? {
        let prod = latenzeSintesi.reduce(0, +), audio = durateSegmenti.reduce(0, +)
        guard prod > 0 else { return nil }
        return audio / velocita / prod
    }
}

struct Segmento: Equatable {
    var ordine: Int
    var indice: Int
    var testo: String
    var url: URL
    var durata: Double
}

/// Lettore italiano: traduce avanti, sintetizza a segmenti, riproduce in background con riserva adattiva.
@MainActor
final class Lettore: ObservableObject {
    enum Stato: Equatable { case fermo, preparazione, riproduzione, pausa, attesa(String), errore(String), finito }

    @Published private(set) var stato: Stato = .fermo
    @Published private(set) var libro: Libro?
    @Published private(set) var testoCorrente = ""
    @Published private(set) var ordineCorrente = 0
    @Published private(set) var riserva = 0.0
    @Published private(set) var metriche = Metriche()
    @Published var velocita: Float = 1.0 { didSet { applicaVelocita() } }
    @Published private(set) var fineTimer: Date?
    @Published private(set) var preparazioneOffline: (fatti: Double, obiettivo: Double)?

    // Parametri iniziali di progetto (da misurare, non risultati): avvio a 12 s, riserva fino a 60 s.
    var avvioSecondi = 12.0
    var riservaObiettivo = 60.0
    var lookaheadTraduzione = 30
    var leggiNote = true
    var annunciaScrittiNonLatini = true
    var identificativoVoce: String?
    var usaAPI = false

    private let libreria: Libreria
    private let apple: TraduttoreApple
    private let player = AVQueuePlayer()
    private let sintesi = SintetizzatoreFile()
    private var produttore: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var segmenti: [ObjectIdentifier: Segmento] = [:]
    private var inCoda: [Segmento] = []
    private var osservatoreTempo: Any?
    private var osservazioni: [NSKeyValueObservation] = []
    private var produzioneFinita = false
    private var inizioStallo: Date?
    private var durateCache: [String: Double] = [:]
    private var traduzioni: ArchivioTraduzioni?
    private var pacchetto: Pacchetto?
    private var avviato = false

    init(libreria: Libreria, apple: TraduttoreApple) {
        self.libreria = libreria
        self.apple = apple
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        configuraSessione()
        configuraComandiRemoti()
        osservatoreTempo = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        osservazioni.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.cambioSegmento() }
        })
    }

    // MARK: sessione audio e comandi

    private func configuraSessione() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.interruzione(n) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            guard let r = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: r) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pausa(causa: "cuffie scollegate") }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
                self?.pausa(causa: "servizi audio riavviati")
            }
        }
    }

    private func interruzione(_ n: Notification) {
        guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let tipo = AVAudioSession.InterruptionType(rawValue: v) else { return }
        switch tipo {
        case .began:
            if stato == .riproduzione { pausa(causa: "interruzione (chiamata o altra app)") }
        case .ended:
            let o = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            if o.contains(.shouldResume), stato == .pausa { riprendi() }
        @unknown default: break
        }
    }

    private func configuraComandiRemoti() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.riprendi() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pausa(causa: nil) }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.stato == .riproduzione ? self?.pausa(causa: nil) : self?.riprendi() }; return .success
        }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.indietro() }; return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.avanti() }; return .success }
    }

    private func aggiornaNowPlaying() {
        guard let l = libro else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: l.titolo,
                                   MPMediaItemPropertyArtist: l.autore ?? "Biblioteca",
                                   MPMediaItemPropertyAlbumTitle: "Biblioteca dell'Iniziato",
                                   MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                                   MPNowPlayingInfoPropertyPlaybackRate: stato == .riproduzione ? Double(velocita) : 0,
                                   MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(velocita)]
        if let item = player.currentItem, let s = segmenti[ObjectIdentifier(item)] {
            info[MPMediaItemPropertyPlaybackDuration] = s.durata
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.currentTime().seconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: comandi utente

    /// Avvia l'ascolto in italiano dal punto salvato (o da `ordine`).
    func ascolta(_ libro: Libro, da ordine: Int? = nil) {
        guard let p = libreria.pacchetto(libro.id) else { stato = .errore("Pacchetto del libro non trovato."); return }
        ferma(salva: self.libro != nil)
        self.libro = libro
        self.pacchetto = p
        traduzioni = ArchivioTraduzioni(cartella: libreria.cartella(libro.id))
        caricaDurate()
        var pos = libreria.posizione(libro.id)
        if let o = ordine { pos = Posizione(ordine: o, segmento: 0, secondi: 0) }
        metriche = Metriche(libro: libro.titolo, motoreTraduzione: usaAPI ? "claude" : "apple",
                            voce: SintetizzatoreFile.voceItaliana(identificativo: identificativoVoce)?.name ?? "predefinita",
                            velocita: Double(velocita), richiesta: Date())
        stato = .preparazione
        avviato = false
        produzioneFinita = false
        try? AVAudioSession.sharedInstance().setActive(true)
        avviaProduzione(da: pos, verso: .riproduzione)
    }

    func pausa(causa: String?) {
        guard stato == .riproduzione || stato == .preparazione || inAttesa else { return }
        player.pause()
        stato = .pausa
        if let c = causa { metriche.interruzioni.append(.init(inizio: Date(), durata: 0, causa: c)) }
        salvaPosizione()
        aggiornaNowPlaying()
    }

    var inAttesa: Bool { if case .attesa = stato { return true }; return false }

    func riprendi() {
        guard libro != nil else { return }
        if stato == .finito || stato == .fermo { if let l = libro { ascolta(l) }; return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if player.currentItem == nil {
            stato = .attesa("Preparo l'audio…")
            if produttore == nil, let l = libro { ascolta(l) }
            return
        }
        player.playImmediately(atRate: velocita)
        stato = .riproduzione
        aggiornaNowPlaying()
    }

    func indietro() { salta(segmenti: -1) }
    func avanti() { salta(segmenti: 1) }

    /// Riparte da un altro segmento: i file già sintetizzati sono in cache, la ripartenza è immediata.
    private func salta(segmenti delta: Int) {
        guard let l = libro, let p = pacchetto else { return }
        var pos = posizioneCorrente()
        pos.secondi = 0
        if delta < 0 {
            if pos.segmento > 0 { pos.segmento -= 1 }
            else if pos.ordine > 0 {
                pos.ordine = precedenteLeggibile(prima: pos.ordine, in: p)
                pos.segmento = max(0, Normalizza.segmentiVoce(p.blocks[pos.ordine].text).count - 1)
            }
        } else {
            pos.segmento += 1
        }
        let eraInRiproduzione = stato == .riproduzione
        ferma(salva: false)
        libro = l; pacchetto = p
        stato = .preparazione
        avviato = false
        produzioneFinita = false
        avviaProduzione(da: pos, verso: eraInRiproduzione ? .riproduzione : .pausa)
    }

    private func precedenteLeggibile(prima o: Int, in p: Pacchetto) -> Int {
        var i = o - 1
        while i > 0, !leggibile(p.blocks[i]) { i -= 1 }
        return max(0, i)
    }

    func timer(minuti: Int?) {
        timerTask?.cancel()
        guard let m = minuti else { fineTimer = nil; return }
        let fine = Date().addingTimeInterval(Double(m) * 60)
        fineTimer = fine
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(m) * 60))
            guard !Task.isCancelled else { return }
            self?.pausa(causa: nil)
            self?.fineTimer = nil
        }
    }

    func segnalibro(nota: String = "") {
        guard let l = libro else { return }
        libreria.aggiungiSegnalibro(Segnalibro(ordine: ordineCorrente, nota: nota), per: l.id)
    }

    func ferma(salva: Bool = true) {
        if salva { salvaPosizione() }
        produttore?.cancel(); produttore = nil
        player.pause()
        player.removeAllItems()
        segmenti.removeAll(); inCoda.removeAll()
        riserva = 0
        stato = .fermo
        Task { await traduzioni?.salva() }
    }

    /// «Prepara un'ora per dopo»: traduce e sintetizza fino a `minuti` di audio senza riprodurre.
    func preparaOffline(_ libro: Libro, minuti: Double = 60) {
        guard let p = libreria.pacchetto(libro.id) else { return }
        ferma(salva: self.libro != nil)
        self.libro = libro; self.pacchetto = p
        traduzioni = ArchivioTraduzioni(cartella: libreria.cartella(libro.id))
        caricaDurate()
        preparazioneOffline = (0, minuti * 60)
        stato = .preparazione
        let pos = libreria.posizione(libro.id)
        let compito = UIApplication.shared.beginBackgroundTask(withName: "prepara-ascolto")
        produttore = Task { [weak self] in
            defer { UIApplication.shared.endBackgroundTask(compito) }
            await self?.produci(da: pos, soloFile: true)
        }
    }

    // MARK: produzione

    private enum Destinazione { case riproduzione, pausa }

    private func avviaProduzione(da pos: Posizione, verso: Destinazione) {
        produttore = Task { [weak self] in
            await self?.produci(da: pos, soloFile: false, avviaInPausa: verso == .pausa)
        }
    }

    func leggibile(_ b: Blocco) -> Bool { leggiNote || !b.eNota }

    private func testoItaliano(_ b: Blocco, libro: Libro) async throws -> String {
        if let s = b.lang, s == "he" || s == "el" {
            return annunciaScrittiNonLatini ? "Segue un passo in \(s == "he" ? "ebraico" : "greco"), consultabile nel testo." : ""
        }
        let sorgente = String((b.lang ?? libro.lingua ?? "it").prefix(2))
        if sorgente == "it" { return b.text }
        if let v = await traduzioni?.voce(b) { return v.testo }
        try await traduciAvanti(da: b.order, sorgente: sorgente, libro: libro)
        if let v = await traduzioni?.voce(b) { return v.testo }
        throw ErroreTraduzione.nonDisponibile("Traduzione mancante per il blocco \(b.id).")
    }

    /// Traduce un lotto di paragrafi della stessa lingua a partire da `ordine` (frasi complete, con contesto).
    private func traduciAvanti(da ordine: Int, sorgente: String, libro: Libro) async throws {
        guard let p = pacchetto, let arch = traduzioni else { return }
        var lotto: [Blocco] = []
        var i = ordine
        var caratteri = 0
        while i < p.blocks.count, lotto.count < 8, caratteri < 6000 {
            let b = p.blocks[i]
            if String((b.lang ?? libro.lingua ?? "it").prefix(2)) == sorgente, await arch.voce(b) == nil {
                lotto.append(b); caratteri += b.text.count
            }
            i += 1
        }
        guard !lotto.isEmpty else { return }
        let motore: MotoreTraduzione = usaAPI && ClienteClaude.chiavePresente ? MotoreClaude() : MotoreApple(traduttore: apple)
        let t0 = Date()
        let tradotti = try await motore.traduci(lotto.map(\.text), da: sorgente)
        metriche.latenzeTraduzione.append(Date().timeIntervalSince(t0))
        for (b, t) in zip(lotto, tradotti) {
            await arch.registra(VoceTraduzione(testo: t, motore: motore.nome, versione: motore.versione, data: Date(),
                                               linguaSorgente: sorgente, hashSorgente: ArchivioTraduzioni.hash(b.text)), per: b.id)
        }
        await arch.salva()
    }

    private func produci(da inizio: Posizione, soloFile: Bool, avviaInPausa: Bool = false) async {
        guard let l = libro, let p = pacchetto else { return }
        let voce = SintetizzatoreFile.voceItaliana(identificativo: identificativoVoce)
        let cartella = libreria.cartellaAudio(l.id)
        var ordine = inizio.ordine
        var primoSegmento = inizio.segmento
        var offsetIniziale = inizio.secondi
        var prodotti = 0.0
        do {
            while ordine < p.blocks.count {
                try Task.checkCancellation()
                let b = p.blocks[ordine]
                if !leggibile(b) { ordine += 1; primoSegmento = 0; continue }
                let it = try await testoItaliano(b, libro: l)
                let pezzi = Normalizza.segmentiVoce(it)
                for k in min(primoSegmento, max(pezzi.count - 1, 0))..<pezzi.count where !pezzi.isEmpty {
                    try Task.checkCancellation()
                    // Riserva piena: aspetta che l'ascolto consumi (niente produzione inutile).
                    while !soloFile, avviato, riservaCorrente() >= riservaObiettivo {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let seg = try await segmento(pezzi[k], ordine: ordine, indice: k, voce: voce, cartella: cartella)
                    prodotti += seg.durata
                    if soloFile {
                        preparazioneOffline?.fatti = prodotti
                        if prodotti >= preparazioneOffline?.obiettivo ?? .infinity { break }
                    } else {
                        accoda(seg, offset: offsetIniziale)
                        offsetIniziale = 0
                        if !avviato, riservaCorrente() >= avvioSecondi { avvia(inPausa: avviaInPausa) }
                    }
                }
                if soloFile, prodotti >= preparazioneOffline?.obiettivo ?? .infinity { break }
                primoSegmento = 0
                ordine += 1
                // Traduzione in anticipo mentre l'app è in primo piano (in background può non essere disponibile).
                if UIApplication.shared.applicationState == .active, ordine < p.blocks.count {
                    let prossimo = min(p.blocks.count - 1, ordine + lookaheadTraduzione)
                    let bb = p.blocks[prossimo]
                    let src = String((bb.lang ?? l.lingua ?? "it").prefix(2))
                    if src != "it", src != "he", src != "el", await traduzioni?.voce(bb) == nil {
                        try? await traduciAvanti(da: max(ordine, prossimo - 7), sorgente: src, libro: l)
                    }
                }
            }
            produzioneFinita = true
            if soloFile { stato = .fermo; preparazioneOffline = nil; await traduzioni?.salva() }
            else if !avviato { avvia(inPausa: avviaInPausa) }
        } catch is CancellationError {
            return
        } catch {
            produzioneFinita = true
            // Nessun passaggio improvviso all'inglese: ci si ferma dichiarando il punto esatto.
            let msg = "Ascolto sospeso al blocco \(ordine + 1): \(error.localizedDescription)"
            if soloFile { stato = .errore(msg); preparazioneOffline = nil }
            else if inCoda.isEmpty || player.currentItem == nil { stato = .errore(msg) }
            else { stato = .attesa(msg) }
        }
    }

    private func segmento(_ testo: String, ordine: Int, indice: Int, voce: AVSpeechSynthesisVoice?, cartella: URL) async throws -> Segmento {
        let chiave = String(format: "%016llx", UInt64(bitPattern: Int64(ArchivioTraduzioni.hash(testo + "|" + (voce?.identifier ?? "")))))
        for est in ["m4a", "caf"] {
            let u = cartella.appendingPathComponent("\(chiave).\(est)")
            if let d = durateCache[chiave], FileManager.default.fileExists(atPath: u.path) {
                return Segmento(ordine: ordine, indice: indice, testo: testo, url: u, durata: d)
            }
        }
        let t0 = Date()
        let (url, durata) = try await sintesi.scrivi(testo, voce: voce, url: cartella.appendingPathComponent("\(chiave).m4a"))
        metriche.latenzeSintesi.append(Date().timeIntervalSince(t0))
        metriche.durateSegmenti.append(durata)
        durateCache[chiave] = durata
        Libreria.scrivi(durateCache, in: cartella.appendingPathComponent("durate.json"))
        return Segmento(ordine: ordine, indice: indice, testo: testo, url: url, durata: durata)
    }

    private func caricaDurate() {
        guard let l = libro else { return }
        durateCache = Libreria.leggi([String: Double].self, da: libreria.cartellaAudio(l.id).appendingPathComponent("durate.json")) ?? [:]
    }

    private func accoda(_ s: Segmento, offset: Double) {
        let item = AVPlayerItem(url: s.url)
        item.audioTimePitchAlgorithm = .timeDomain
        if offset > 0.5 { item.seek(to: CMTime(seconds: offset, preferredTimescale: 600), completionHandler: nil) }
        segmenti[ObjectIdentifier(item)] = s
        inCoda.append(s)
        player.insert(item, after: nil)
        if let i = inizioStallo, avviato, stato != .pausa {
            metriche.interruzioni.append(.init(inizio: i, durata: Date().timeIntervalSince(i), causa: "riserva esaurita"))
            inizioStallo = nil
            player.playImmediately(atRate: velocita)
            stato = .riproduzione
        }
        riserva = riservaCorrente()
    }

    private func avvia(inPausa: Bool) {
        avviato = true
        if metriche.primoAudioSecondi == nil { metriche.primoAudioSecondi = Date().timeIntervalSince(metriche.richiesta) }
        if inPausa { stato = .pausa } else {
            player.playImmediately(atRate: velocita)
            stato = .riproduzione
        }
        cambioSegmento()
    }

    private func riservaCorrente() -> Double {
        guard let item = player.currentItem, let cur = segmenti[ObjectIdentifier(item)],
              let i = inCoda.firstIndex(of: cur) else { return inCoda.reduce(0) { $0 + $1.durata } }
        let restante = max(0, cur.durata - item.currentTime().seconds)
        return inCoda[(i + 1)...].reduce(restante) { $0 + $1.durata }
    }

    private func cambioSegmento() {
        if let item = player.currentItem, let s = segmenti[ObjectIdentifier(item)] {
            if let i = inCoda.firstIndex(of: s), i > 0 {
                for vecchio in inCoda[..<i] { metriche.secondiAscoltati += vecchio.durata }
                inCoda.removeFirst(i)
            }
            testoCorrente = s.testo
            ordineCorrente = s.ordine
            salvaPosizione()
        } else if avviato, stato == .riproduzione {
            metriche.secondiAscoltati += inCoda.reduce(0) { $0 + $1.durata }
            inCoda.removeAll()
            if produzioneFinita { stato = .finito; libro.map { libreria.salvaPosizione(Posizione(), per: $0.id) } }
            else { inizioStallo = Date(); stato = .attesa("Preparo l'audio…") }
        }
        aggiornaNowPlaying()
    }

    private func tick() {
        guard libro != nil else { return }
        let r = riservaCorrente()
        riserva = r
        if avviato, stato == .riproduzione {
            metriche.riservaMinima = min(metriche.riservaMinima ?? r, r)
        }
        if Int(Date().timeIntervalSince1970) % 5 == 0 { salvaPosizione(); aggiornaNowPlaying() }
    }

    private func applicaVelocita() {
        player.defaultRate = velocita
        if stato == .riproduzione { player.rate = velocita }
        metriche.velocita = Double(velocita)
        aggiornaNowPlaying()
    }

    private func posizioneCorrente() -> Posizione {
        if let item = player.currentItem, let s = segmenti[ObjectIdentifier(item)] {
            return Posizione(ordine: s.ordine, segmento: s.indice, secondi: max(0, item.currentTime().seconds))
        }
        return libro.map { libreria.posizione($0.id) } ?? Posizione()
    }

    private func salvaPosizione() {
        guard let l = libro, player.currentItem != nil else { return }
        libreria.salvaPosizione(posizioneCorrente(), per: l.id)
    }

    /// File JSON delle metriche, da condividere dopo la prova fisica.
    func esportaMetriche() -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("metriche-ascolto.json")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(metriche) else { return nil }
        try? d.write(to: u)
        return u
    }
}
