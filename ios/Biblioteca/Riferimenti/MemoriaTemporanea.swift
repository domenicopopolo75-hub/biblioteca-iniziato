import Foundation

/// Memoria temporanea per ciò che serve a leggere (pagine, file recuperati da Drive o dal web).
/// Ha un limite di spazio, scarta le voci meno recenti e si può svuotare in ogni momento
/// senza perdere riferimenti, appunti o copie conservate volontariamente: stanno altrove.
final class MemoriaTemporanea: @unchecked Sendable {
    static let limitePredefinito: Int64 = 150 * 1024 * 1024

    struct Meta: Codable { var tipo: String?; var scaricatoIl: Date }

    let cartella: URL
    let limiteByte: Int64
    private let blocco = NSLock()

    init(cartella: URL? = nil, limiteByte: Int64 = MemoriaTemporanea.limitePredefinito) {
        self.cartella = cartella ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BibliotecaTemporanea", isDirectory: true)
        self.limiteByte = limiteByte
        try? FileManager.default.createDirectory(at: self.cartella, withIntermediateDirectories: true)
    }

    private func percorso(_ chiave: String) -> URL { cartella.appendingPathComponent(Impronta.sha256(chiave)) }

    func leggi(_ chiave: String, eta massima: TimeInterval? = nil) -> (dati: Data, meta: Meta)? {
        blocco.lock(); defer { blocco.unlock() }
        let base = percorso(chiave)
        guard let d = try? Data(contentsOf: base.appendingPathExtension("dat")),
              let m = Libreria.leggi(Meta.self, da: base.appendingPathExtension("meta")) else { return nil }
        if let massima, Date().timeIntervalSince(m.scaricatoIl) > massima { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: base.appendingPathExtension("dat").path)
        return (d, m)
    }

    /// Un contenuto più grande dell'intero limite non viene tenuto: chi lo usa lo ha già in mano per questa lettura.
    @discardableResult
    func scrivi(_ dati: Data, chiave: String, tipo: String? = nil) -> Bool {
        guard Int64(dati.count) <= limiteByte else { return false }
        blocco.lock(); defer { blocco.unlock() }
        let base = percorso(chiave)
        do {
            try dati.write(to: base.appendingPathExtension("dat"), options: .atomic)
            Libreria.scrivi(Meta(tipo: tipo, scaricatoIl: Date()), in: base.appendingPathExtension("meta"))
        } catch { return false }
        riduciSenzaBlocco()
        return true
    }

    /// Spazio occupato, in byte.
    var occupazione: Int64 {
        blocco.lock(); defer { blocco.unlock() }
        return voci().reduce(0) { $0 + $1.byte }
    }

    var numeroVoci: Int {
        blocco.lock(); defer { blocco.unlock() }
        return voci().filter { $0.url.pathExtension == "dat" }.count
    }

    /// Toglie tutto: riferimenti, appunti, copie conservate e preparazione offline per l'ascolto non sono qui.
    func svuota() {
        blocco.lock(); defer { blocco.unlock() }
        try? FileManager.default.removeItem(at: cartella)
        try? FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
    }

    func riduci() {
        blocco.lock(); defer { blocco.unlock() }
        riduciSenzaBlocco()
    }

    private struct Voce { var url: URL; var byte: Int64; var data: Date }

    private func voci() -> [Voce] {
        let chiavi: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let elenco = (try? FileManager.default.contentsOfDirectory(at: cartella, includingPropertiesForKeys: chiavi)) ?? []
        return elenco.map { u in
            let v = try? u.resourceValues(forKeys: Set(chiavi))
            return Voce(url: u, byte: Int64(v?.fileSize ?? 0), data: v?.contentModificationDate ?? .distantPast)
        }
    }

    /// Scarta le voci lette meno di recente finché si rientra nel limite.
    private func riduciSenzaBlocco() {
        var tutte = voci()
        var totale = tutte.reduce(0) { $0 + $1.byte }
        guard totale > limiteByte else { return }
        tutte.sort { $0.data < $1.data }
        for v in tutte where totale > limiteByte {
            try? FileManager.default.removeItem(at: v.url)
            totale -= v.byte
        }
    }
}
