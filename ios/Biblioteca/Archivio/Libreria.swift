import Foundation

struct Libro: Codable, Identifiable, Equatable, Hashable {
    var id: String               // sha256 dell'originale = identità dell'edizione
    var titolo: String
    var autore: String?
    var lingua: String?
    var formato: String
    var nomeOriginale: String
    var estensione: String
    var importatoIl: Date
    var blocchi: Int
    var unitaTotali: Int
    var unitaConTesto: Int
    var unitaOCR: Int
    var unitaSenzaTesto: Int

    var daTradurre: Bool { !(lingua ?? "it").hasPrefix("it") }
}

struct VoceTraduzione: Codable, Equatable {
    var testo: String
    var motore: String          // "apple" | "claude:<modello>"
    var versione: String
    var data: Date
    var linguaSorgente: String
    var hashSorgente: Int       // hash del testo originale al momento della traduzione
}

struct Posizione: Codable, Equatable {
    var ordine: Int = 0          // blocco in ordine di lettura
    var segmento: Int = 0        // frase/gruppo dentro il blocco
    var secondi: Double = 0      // offset nel segmento
    var aggiornata = Date()
}

struct Segnalibro: Codable, Equatable, Identifiable {
    var id = UUID()
    var ordine: Int
    var nota: String
    var creato = Date()
}

/// Archivio locale: Application Support/Biblioteca/<id>/{originale.*, pacchetto.json, traduzioni-it.json, audio/, posizione.json}
@MainActor
final class Libreria: ObservableObject {
    @Published private(set) var libri: [Libro] = []
    @Published var ultimoErrore: String?
    @Published var importazioneInCorso: String?

    let radice: URL
    private var cachePacchetti: [String: Pacchetto] = [:]

    init(radice: URL? = nil) {
        let base = radice ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Biblioteca", isDirectory: true)
        self.radice = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var esclusa = base
        var v = URLResourceValues(); v.isExcludedFromBackup = false
        try? esclusa.setResourceValues(v)
        caricaIndice()
    }

    // MARK: percorsi

    func cartella(_ id: String) -> URL { radice.appendingPathComponent(id, isDirectory: true) }
    func originale(_ l: Libro) -> URL { cartella(l.id).appendingPathComponent("originale.\(l.estensione)") }
    func cartellaAudio(_ id: String) -> URL {
        let u = cartella(id).appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private var indice: URL { radice.appendingPathComponent("libreria.json") }

    private func caricaIndice() {
        guard let d = try? Data(contentsOf: indice) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        libri = (try? dec.decode([Libro].self, from: d)) ?? []
    }

    private func salvaIndice() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(libri).write(to: indice, options: .atomic)
    }

    // MARK: importazione

    /// Importa un file scelto dall'utente. Deduplica per hash: lo stesso file non crea un secondo libro.
    @discardableResult
    func importa(_ sorgente: URL) async -> Libro? {
        let accesso = sorgente.startAccessingSecurityScopedResource()
        defer { if accesso { sorgente.stopAccessingSecurityScopedResource() } }
        importazioneInCorso = sorgente.lastPathComponent
        defer { importazioneInCorso = nil }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + sorgente.lastPathComponent)
            try FileManager.default.copyItem(at: sorgente, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let sha = try Importatore.sha256(tmp)
            if let gia = libri.first(where: { $0.id == sha }) { return gia }
            let pacchetto = try await Task.detached(priority: .userInitiated) {
                try Importatore.pacchetto(per: tmp, sha: sha)
            }.value
            // Un pacchetto .bibl.json prodotto da pipeline/ ha l'identità dell'edizione originale.
            let id = tmp.pathExtension.lowercased() == "json" ? pacchetto.edition.source_sha256 : sha
            if let gia = libri.first(where: { $0.id == id }) { return gia }
            let dir = cartella(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let est = tmp.pathExtension.lowercased() == "json" ? "bibl.json" : tmp.pathExtension.lowercased()
            let dest = dir.appendingPathComponent("originale.\(est)")
            if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: tmp, to: dest) }
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dest.path)
            try JSONEncoder().encode(pacchetto).write(to: dir.appendingPathComponent("pacchetto.json"), options: .atomic)
            let c = pacchetto.coverage
            let libro = Libro(id: id, titolo: pacchetto.work.title, autore: pacchetto.work.author,
                              lingua: pacchetto.work.language, formato: pacchetto.edition.format,
                              nomeOriginale: sorgente.lastPathComponent, estensione: est, importatoIl: Date(),
                              blocchi: pacchetto.blocks.count, unitaTotali: c.units_total,
                              unitaConTesto: c.units_with_text, unitaOCR: c.units_ocr?.count ?? 0,
                              unitaSenzaTesto: c.units_need_ocr.count)
            libri.insert(libro, at: 0)
            cachePacchetti[id] = pacchetto
            salvaIndice()
            return libro
        } catch {
            ultimoErrore = "\(sorgente.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func aggiornaLingua(_ libro: Libro, lingua: String) {
        guard let i = libri.firstIndex(of: libro) else { return }
        libri[i].lingua = lingua
        salvaIndice()
    }

    func elimina(_ libro: Libro) {
        let dir = cartella(libro.id)
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: originale(libro).path)
        try? FileManager.default.removeItem(at: dir)
        libri.removeAll { $0.id == libro.id }
        cachePacchetti[libro.id] = nil
        salvaIndice()
    }

    // MARK: dati per libro

    func pacchetto(_ id: String) -> Pacchetto? {
        if let p = cachePacchetti[id] { return p }
        guard let d = try? Data(contentsOf: cartella(id).appendingPathComponent("pacchetto.json")),
              let p = try? JSONDecoder().decode(Pacchetto.self, from: d) else { return nil }
        cachePacchetti[id] = p
        return p
    }

    nonisolated static func leggi<T: Decodable>(_ t: T.Type, da url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(t, from: d)
    }

    nonisolated static func scrivi<T: Encodable>(_ v: T, in url: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(v).write(to: url, options: .atomic)
    }

    func posizione(_ id: String) -> Posizione {
        Self.leggi(Posizione.self, da: cartella(id).appendingPathComponent("posizione.json")) ?? Posizione()
    }
    func salvaPosizione(_ p: Posizione, per id: String) {
        Self.scrivi(p, in: cartella(id).appendingPathComponent("posizione.json"))
    }
    func segnalibri(_ id: String) -> [Segnalibro] {
        Self.leggi([Segnalibro].self, da: cartella(id).appendingPathComponent("segnalibri.json")) ?? []
    }
    func aggiungiSegnalibro(_ s: Segnalibro, per id: String) {
        Self.scrivi(segnalibri(id) + [s], in: cartella(id).appendingPathComponent("segnalibri.json"))
    }
}

/// Traduzioni italiane allineate ai blocchi, salvate per libro. Thread-safe (actor).
actor ArchivioTraduzioni {
    private let url: URL
    private var voci: [String: VoceTraduzione]

    init(cartella: URL) {
        url = cartella.appendingPathComponent("traduzioni-it.json")
        voci = Libreria.leggi([String: VoceTraduzione].self, da: url) ?? [:]
    }

    func voce(_ blocco: Blocco) -> VoceTraduzione? {
        guard let v = voci[blocco.id], v.hashSorgente == Self.hash(blocco.text) else { return nil }
        return v
    }

    func registra(_ v: VoceTraduzione, per id: String) {
        voci[id] = v
    }

    func salva() { Libreria.scrivi(voci, in: url) }

    var conteggio: Int { voci.count }

    /// Hash stabile tra avvii (String.hashValue non lo è).
    static func hash(_ s: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }
}
