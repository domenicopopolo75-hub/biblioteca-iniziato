import Foundation

/// Catalogo dei riferimenti e degli appunti. Vive in Application Support, separato dalla memoria temporanea:
/// svuotare la memoria temporanea non lo tocca.
@MainActor
final class Registro: ObservableObject {
    @Published private(set) var riferimenti: [Riferimento] = []
    @Published private(set) var appunti: [Appunto] = []

    private let fileRiferimenti: URL
    private let fileAppunti: URL

    init(radice: URL) {
        try? FileManager.default.createDirectory(at: radice, withIntermediateDirectories: true)
        fileRiferimenti = radice.appendingPathComponent("riferimenti.json")
        fileAppunti = radice.appendingPathComponent("appunti.json")
        riferimenti = Libreria.leggi([Riferimento].self, da: fileRiferimenti) ?? []
        appunti = Libreria.leggi([Appunto].self, da: fileAppunti) ?? []
    }

    func trova(_ id: String) -> Riferimento? { riferimenti.first { $0.id == id } }

    /// Salva la scheda. Idempotente: lo stesso materiale non crea una seconda scheda; i dati già raccolti
    /// (consultazioni, copia, stato) non vengono azzerati da un nuovo salvataggio.
    @discardableResult
    func salva(_ nuovo: Riferimento) -> Riferimento {
        if let i = riferimenti.firstIndex(where: { $0.id == nuovo.id }) {
            var r = riferimenti[i]
            if r.autore == nil { r.autore = nuovo.autore }
            if r.lingua == nil { r.lingua = nuovo.lingua }
            if r.formato == nil { r.formato = nuovo.formato }
            if r.identificativoRemoto == nil { r.identificativoRemoto = nuovo.identificativoRemoto }
            if nuovo.livello > r.livello { r.livello = nuovo.livello }
            if r.impronta == nil { r.impronta = nuovo.impronta }
            if let u = nuovo.ultimaConsultazione, (r.ultimaConsultazione ?? .distantPast) < u { r.ultimaConsultazione = u }
            if r.titoloProvvisorio == true, nuovo.titoloProvvisorio != true { r.titolo = nuovo.titolo; r.titoloProvvisorio = nil }
            if nuovo.testoDisponibile != nil { r.testoDisponibile = nuovo.testoDisponibile }
            riferimenti[i] = r
            scriviRiferimenti()
            return r
        }
        riferimenti.insert(nuovo, at: 0)
        scriviRiferimenti()
        return nuovo
    }

    func aggiorna(_ id: String, _ modifica: (inout Riferimento) -> Void) {
        guard let i = riferimenti.firstIndex(where: { $0.id == id }) else { return }
        modifica(&riferimenti[i])
        scriviRiferimenti()
    }

    /// Eliminazione volontaria della scheda: tolgono anche gli appunti collegati, quindi la UI chiede conferma.
    /// La copia conservata in biblioteca, se c'è, non viene toccata.
    func elimina(_ id: String) {
        riferimenti.removeAll { $0.id == id }
        appunti.removeAll { $0.riferimentoId == id }
        scriviRiferimenti()
        scriviAppunti()
    }

    func appunti(per id: String) -> [Appunto] {
        appunti.filter { $0.riferimentoId == id }.sorted { $0.creato < $1.creato }
    }

    func aggiungi(_ a: Appunto) {
        appunti.append(a)
        scriviAppunti()
    }

    func rimuovi(appunto id: UUID) {
        appunti.removeAll { $0.id == id }
        scriviAppunti()
    }

    private func scriviRiferimenti() { Libreria.scrivi(riferimenti, in: fileRiferimenti) }
    private func scriviAppunti() { Libreria.scrivi(appunti, in: fileAppunti) }
}
