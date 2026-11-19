import Foundation

/// Ricerca unica con provenienza chiara: telefono, Drive, fonti online.
/// Dichiara quali fonti sono state davvero interrogate e quali no: non si presenta come ricerca su tutta Internet.
@MainActor
final class Ricerca: ObservableObject {
    struct EsitoFonte: Identifiable, Equatable {
        enum Stato: Equatable {
            case interrogata(Int)            // numero di risultati
            case nonRaggiungibile(String)    // interrogata ma non ha risposto
            case nonInterrogata(String)      // non interrogata, con il motivo
        }
        var id: String
        var nome: String
        var origine: Origine
        var stato: Stato
        var dettaglio: String? = nil
    }

    @Published private(set) var risultati: [Risultato] = []
    @Published private(set) var esiti: [EsitoFonte] = []
    @Published private(set) var inCorso = false
    @Published private(set) var ultimaRicerca: String?

    let libreria: Libreria
    let drive: SorgenteDrive
    let online: RicercaOnline

    init(libreria: Libreria, drive: SorgenteDrive, online: RicercaOnline) {
        self.libreria = libreria; self.drive = drive; self.online = online
    }

    func cerca(_ testo: String) async {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return }
        inCorso = true
        defer { inCorso = false }
        var telefono: [Risultato] = [], daDrive: [Risultato] = [], esterni: [Risultato] = []
        var elenco: [EsitoFonte] = []

        // 1. Già sul telefono: indice locale e titoli.
        let locali = cercaSulTelefono(t)
        telefono = locali
        elenco.append(.init(id: "telefono", nome: "Biblioteca sul telefono", origine: .telefono, stato: .interrogata(locali.count),
                            dettaglio: "\(libreria.libri.count) libri, testo e titoli"))

        // 2. Drive.
        if drive.collegato {
            do {
                let voci = try await drive.cerca(t).filter { !$0.cartella }
                daDrive = voci.map(risultatoDrive)
                elenco.append(.init(id: "drive", nome: "Google Drive", origine: .drive, stato: .interrogata(daDrive.count),
                                    dettaglio: "nome e testo dei file, primi 50"))
            } catch {
                elenco.append(.init(id: "drive", nome: "Google Drive", origine: .drive,
                                    stato: .nonRaggiungibile(error.localizedDescription)))
            }
        } else {
            elenco.append(.init(id: "drive", nome: "Google Drive", origine: .drive,
                                stato: .nonInterrogata("non collegato: accedi da Aggiungi › Da Google Drive o dalle Impostazioni")))
        }

        // 3. Fonti online supportate, in parallelo, ciascuna isolata dalle altre.
        let ricerca = online
        let esitiOnline = await withTaskGroup(of: (DescrizioneFonte, Result<RicercaOnline.Esito, Error>).self) { gruppo in
            for f in FontiOnline.supportate {
                gruppo.addTask {
                    do { return (f, .success(try await ricerca.cerca(f, t))) } catch { return (f, .failure(error)) }
                }
            }
            var tutti: [(DescrizioneFonte, Result<RicercaOnline.Esito, Error>)] = []
            for await r in gruppo { tutti.append(r) }
            return tutti
        }
        for f in FontiOnline.supportate {
            guard let (_, r) = esitiOnline.first(where: { $0.0.id == f.id }) else { continue }
            switch r {
            case .success(let e):
                esterni += e.risultati.map(collega)
                elenco.append(.init(id: f.id, nome: f.nome, origine: .esterno, stato: .interrogata(e.risultati.count), dettaglio: e.dettaglio))
            case .failure(let err):
                elenco.append(.init(id: f.id, nome: f.nome, origine: .esterno,
                                    stato: .nonRaggiungibile(err.localizedDescription)))
            }
        }
        for f in FontiOnline.escluse {
            elenco.append(.init(id: f.id, nome: f.nome, origine: .esterno, stato: .nonInterrogata(f.motivo ?? "non supportata")))
        }

        risultati = (telefono + daDrive + esterni).map(collega)
        esiti = elenco
        ultimaRicerca = t
    }

    // MARK: telefono

    private func cercaSulTelefono(_ testo: String) -> [Risultato] {
        let termini = RicercaOnline.termini(testo)
        var migliore: [String: Indice.Riscontro] = [:]
        for r in libreria.indice.cerca(termini, limite: 60) where migliore[r.libro] == nil { migliore[r.libro] = r }
        var out: [Risultato] = []
        for l in libreria.libri {
            let titoloOk = RicercaOnline.sufficiente(RicercaOnline.punteggio(termini, l.titolo + " " + (l.autore ?? "")), di: termini)
            guard titoloOk || migliore[l.id] != nil else { continue }
            out.append(Risultato(id: "telefono:\(l.id)", titolo: l.titolo, autore: l.autore, origine: .telefono,
                                 nomeFonte: l.nomeFonte ?? "Biblioteca sul telefono", collegamento: "", lingua: l.lingua,
                                 formato: l.formato, accesso: .consultabile, anteprima: migliore[l.id]?.estratto, libroId: l.id))
        }
        return out
    }

    // MARK: Drive

    private func risultatoDrive(_ v: GoogleDrive.Voce) -> Risultato {
        let ext = (v.name as NSString).pathExtension.lowercased()
        let conosciuta = ["pdf", "epub", "txt", "md", "json", "html", "htm"].contains(ext)
        let titolo = conosciuta ? (v.name as NSString).deletingPathExtension : v.name
        let formato: String? = conosciuta ? ext : (v.documentoGoogle ? "documento Google" : (ext.isEmpty ? nil : ext))
        return Risultato(id: Riferimento.identita(origine: .drive, chiave: v.id), titolo: titolo, origine: .drive,
                         nomeFonte: "Google Drive",
                         collegamento: v.webViewLink ?? "https://drive.google.com/file/d/\(v.id)/view",
                         lingua: nil, formato: formato, tipoMime: v.mimeType,
                         accesso: v.importabile ? .consultabile : .soloCollegamento,
                         identificativoRemoto: v.id, versioneRemota: v.md5Checksum ?? v.modifiedTime)
    }

    /// Se una copia è già in biblioteca, il risultato lo dice (stesso materiale: nessun doppione da proporre).
    private func collega(_ r: Risultato) -> Risultato {
        guard r.libroId == nil else { return r }
        var x = r
        let prov = Consultazione.provenienza(r)
        x.libroId = libreria.libro(conProvenienza: prov)?.id
        return x
    }
}
