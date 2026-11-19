import Foundation

/// Drive visto dalla ricerca e dalla consultazione. Dietro un'interfaccia per provarlo senza account.
@MainActor
protocol SorgenteDrive: AnyObject {
    var collegato: Bool { get }
    func cerca(_ testo: String) async throws -> [GoogleDrive.Voce]
    func contenuto(_ v: GoogleDrive.Voce) async throws -> (dati: Data, nome: String)
}

extension GoogleDrive: SorgenteDrive {
    func contenuto(_ v: GoogleDrive.Voce) async throws -> (dati: Data, nome: String) {
        if let b = v.size.flatMap({ Int64($0) }), b > Consultazione.limiteFile { throw ErroreFonte.troppoGrande(b) }
        let tmp: URL, nome: String
        do { (tmp, nome) = try await scarica(v) } catch let e as NSError where e.domain == "Drive" {
            switch e.code {
            case 404: throw ErroreFonte.scomparsa(404)
            case 401, 403: throw ErroreFonte.negato(e.code)
            default: throw ErroreFonte.rete(e.localizedDescription)
            }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dim = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if dim > Consultazione.limiteFile { throw ErroreFonte.troppoGrande(dim) }
        return (try Data(contentsOf: tmp), nome)
    }
}

/// Tre azioni distinte, una sola responsabilità ciascuna:
/// - `leggi`: recupera il contenuto in modo temporaneo e lo mostra; non crea file permanenti;
/// - il registro (`salva`): conserva scheda e collegamento, mai il contenuto;
/// - `conserva`: acquisisce stabilmente una copia, solo dopo una scelta esplicita, senza duplicati.
@MainActor
final class Consultazione: ObservableObject {
    static let limiteFile: Int64 = 60 * 1024 * 1024

    let rete: Scaricatore
    let memoria: MemoriaTemporanea
    let drive: SorgenteDrive
    let libreria: Libreria
    let registro: Registro

    init(rete: Scaricatore, memoria: MemoriaTemporanea, drive: SorgenteDrive, libreria: Libreria, registro: Registro) {
        self.rete = rete; self.memoria = memoria; self.drive = drive; self.libreria = libreria; self.registro = registro
    }

    struct Contenuto {
        var dati: Data
        var nome: String
        var estensione: String
    }

    struct Letto {
        var pacchetto: Pacchetto
        var livello: LivelloLettura
        var impronta: String
        var avviso: String?
        var data: Date
    }

    // MARK: recupero temporaneo

    func recupera(_ r: Risultato, aggiorna: Bool = false) async throws -> Contenuto {
        switch r.origine {
        case .telefono:
            throw ErroreFonte.nonConsultabile("Il libro è già nella biblioteca: aprilo da lì.")
        case .drive:
            guard let id = r.identificativoRemoto else { throw ErroreFonte.nonConsultabile("Riferimento Drive senza identificativo.") }
            guard drive.collegato else { throw ErroreFonte.nonConsultabile("Accedi a Google Drive per consultare questo file.") }
            let chiave = "drive:\(id):\(r.versioneRemota ?? "")"
            let ext = Self.estensione(formato: r.formato, tipo: r.tipoMime)
            if !aggiorna, let c = memoria.leggi(chiave, eta: 3600) {
                return Contenuto(dati: c.dati, nome: Self.nomeFile(r.titolo, ext), estensione: ext)
            }
            let nomeDrive = r.tipoMime == "application/vnd.google-apps.document" ? r.titolo : Self.nomeFile(r.titolo, ext)
            let voce = GoogleDrive.Voce(id: id, name: nomeDrive, mimeType: r.tipoMime ?? "")
            let (d, nome) = try await drive.contenuto(voce)
            memoria.scrivi(d, chiave: chiave, tipo: ext)
            return Contenuto(dati: d, nome: nome, estensione: (nome as NSString).pathExtension.lowercased().isEmpty ? ext : (nome as NSString).pathExtension.lowercased())
        case .esterno:
            var url = URL(string: r.collegamento)
            var ext = Self.estensione(formato: r.formato, tipo: nil, url: url)
            if let ident = r.identificativoRemoto, r.collegamento.contains("archive.org") {
                (url, ext) = try await risolviArchive(ident)
            }
            guard let u = url else { throw ErroreFonte.nonConsultabile("Collegamento non valido.") }
            let chiave = u.absoluteString
            if !aggiorna, let c = memoria.leggi(chiave, eta: 3600) {
                return Contenuto(dati: c.dati, nome: Self.nomeFile(r.titolo, ext), estensione: ext)
            }
            let (d, tipo) = try await rete.dati(u, massimoByte: Self.limiteFile)
            if r.formato == nil || r.formato == "html", ext == "html", let tipo, tipo.contains("pdf") { ext = "pdf" }
            memoria.scrivi(d, chiave: chiave, tipo: tipo)
            return Contenuto(dati: d, nome: Self.nomeFile(r.titolo, ext), estensione: ext)
        }
    }

    /// Internet Archive: sceglie il file originale EPUB (o PDF) tra quelli dell'elemento, come fa il servizio.
    func risolviArchive(_ identificativo: String) async throws -> (URL?, String) {
        let meta = URL(string: "https://archive.org/metadata/\(identificativo)")!
        let (d, _) = try await rete.dati(meta, massimoByte: 8 * 1024 * 1024)
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let files = j["files"] as? [[String: Any]] else { throw ErroreFonte.rete("metadati dell'elemento non leggibili") }
        let originali = files.filter { ($0["source"] as? String) == "original" }
        for ext in ["epub", "pdf"] {
            let candidati = originali.filter { (($0["name"] as? String) ?? "").lowercased().hasSuffix("." + ext) }
                .sorted { (Int64($0["size"] as? String ?? "") ?? 0) > (Int64($1["size"] as? String ?? "") ?? 0) }
            if let nome = candidati.first?["name"] as? String,
               let u = URL(string: "https://archive.org/download/\(identificativo)/" + (nome.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nome)) {
                return (u, ext)
            }
        }
        throw ErroreFonte.nonConsultabile("Nessun PDF o EPUB originale scaricabile: apri la fonte dal sito.")
    }

    static func estensione(formato: String?, tipo: String?, url: URL? = nil) -> String {
        if let f = formato?.lowercased(), ["pdf", "epub", "txt", "md", "html", "htm", "json"].contains(f) { return f == "htm" ? "html" : f }
        if tipo == "application/vnd.google-apps.document" { return "txt" }
        if let e = url?.pathExtension.lowercased(), ["pdf", "epub", "txt", "md"].contains(e) { return e }
        return "html"
    }

    static func nomeFile(_ titolo: String, _ ext: String) -> String {
        let base = titolo.replacingOccurrences(of: "[\\\\/:*?\"<>|\\n\\r\\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let pulito = String((base.isEmpty ? "materiale" : base).prefix(120))
        return pulito.lowercased().hasSuffix("." + ext) ? pulito : "\(pulito).\(ext)"
    }

    // MARK: lettura (in memoria)

    /// Recupera il contenuto, ne estrae il testo e lo valuta. Se il riferimento è salvato ne aggiorna provenienza,
    /// data di consultazione, livello e stato della fonte (cambiata / non raggiungibile).
    func leggi(_ r: Risultato, aggiorna: Bool = false) async throws -> Letto {
        do {
            let c = try await recupera(r, aggiorna: aggiorna)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let f = dir.appendingPathComponent(c.nome)
            try c.dati.write(to: f)
            let sha = Impronta.sha256(c.dati)
            let indirizzo = r.collegamento
            let p = try await Task.detached(priority: .userInitiated) {
                try Importatore.pacchetto(per: f, sha: sha, indirizzo: indirizzo)
            }.value
            var livello = LivelloLettura.per(pacchetto: p)
            var avviso: String?
            if c.estensione == "html", p.blocks.reduce(0, { $0 + $1.text.count }) < 300 {
                livello = min(livello, .parziale)
                avviso = "La pagina contiene pochissimo testo: potrebbe caricarlo con JavaScript. Apri la fonte originale."
            } else if livello == .parziale {
                avviso = "Alcune pagine non hanno testo leggibile: la lettura è parziale."
            }
            let l = Letto(pacchetto: p, livello: livello, impronta: Impronta.testo(p), avviso: avviso, data: Date())
            registraConsultazione(r.id, l)
            return l
        } catch let e as ErroreFonte {
            registraErrore(r.id, e)
            throw e
        }
    }

    private func registraConsultazione(_ id: String, _ l: Letto) {
        registro.aggiorna(id) { r in
            if let vecchia = r.impronta, vecchia != l.impronta {
                r.stato = .cambiata
                r.notaStato = "Il contenuto è cambiato rispetto alla consultazione del "
                    + (r.ultimaConsultazione ?? l.data).formatted(date: .abbreviated, time: .omitted)
                    + ". Gli appunti restano collegati alla versione che avevi visto."
            } else {
                r.stato = .verificata
                r.notaStato = nil
            }
            r.impronta = l.impronta
            r.ultimaConsultazione = l.data
            r.testoDisponibile = true
            if l.livello > r.livello || r.stato == .cambiata { r.livello = l.livello }
            if r.titoloProvvisorio == true, let t = l.pacchetto.work.title.nilSeVuoto {
                r.titolo = t; r.titoloProvvisorio = nil
            }
            if r.autore == nil { r.autore = l.pacchetto.work.author }
            if r.lingua == nil { r.lingua = l.pacchetto.work.language }
        }
    }

    private func registraErrore(_ id: String, _ e: ErroreFonte) {
        registro.aggiorna(id) { r in
            guard e.fonteNonRaggiungibile else { return }
            r.stato = .nonRaggiungibile
            r.notaStato = (e.errorDescription ?? "") + " Verificato il " + Date().formatted(date: .abbreviated, time: .shortened)
                + ". Scheda e appunti restano."
        }
    }

    // MARK: azioni sul registro

    /// «Salva riferimento»: scheda e collegamento, niente contenuto.
    @discardableResult
    func salvaRiferimento(_ r: Risultato, letto: Letto? = nil) -> Riferimento {
        var nuovo = r.comeRiferimento()
        if let l = letto {
            nuovo.livello = l.livello
            nuovo.impronta = l.impronta
            nuovo.ultimaConsultazione = l.data
            nuovo.testoDisponibile = true
            nuovo.stato = .verificata
        } else if r.anteprima != nil {
            nuovo.livello = .riferimento     // lo snippet della ricerca non conta come lettura
        }
        return registro.salva(nuovo)
    }

    static func provenienza(_ r: Risultato) -> String {
        r.origine == .drive ? "drive:\(r.identificativoRemoto ?? r.id)" : RicercaOnline.canonico(r.collegamento)
    }

    /// «Conserva una copia»: scelta esplicita. Un secondo tentativo riconosce la copia già fatta (per riferimento,
    /// per provenienza e per contenuto) e non crea duplicati.
    func conserva(_ r: Risultato) async throws -> Libro {
        let rif = salvaRiferimento(r)
        if let id = rif.copiaId, let l = libreria.libri.first(where: { $0.id == id }) { return l }
        let prov = Self.provenienza(r)
        if let l = libreria.libro(conProvenienza: prov) {
            registro.aggiorna(r.id) { $0.copiaId = l.id }
            return l
        }
        do {
            let c = try await recupera(r)
            guard let libro = await libreria.importa(dati: try Self.scriviTemporaneo(c), nome: c.nome,
                                                     provenienza: prov, nomeFonte: r.nomeFonte) else {
                throw ErroreFonte.nonConsultabile(libreria.ultimoErrore ?? "Importazione non riuscita.")
            }
            let completo = libro.unitaSenzaTesto == 0 && libro.unitaConTesto >= libro.unitaTotali
            registro.aggiorna(r.id) {
                $0.copiaId = libro.id
                $0.testoDisponibile = true
                $0.ultimaConsultazione = Date()
                if (completo ? LivelloLettura.completo : .parziale) > $0.livello { $0.livello = completo ? .completo : .parziale }
            }
            return libro
        } catch let e as ErroreFonte {
            registraErrore(r.id, e)
            throw e
        }
    }

    private static func scriviTemporaneo(_ c: Contenuto) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("recupero-" + UUID().uuidString)
        try c.dati.write(to: f)
        return f
    }

    // MARK: appunti

    func aggiungiAppunto(_ r: Risultato, letto: Letto, blocco: Blocco, nota: String) {
        salvaRiferimento(r, letto: letto)
        registro.aggiungi(Appunto(
            riferimentoId: r.id,
            passaggio: blocco.locator.descrizione(formato: letto.pacchetto.edition.format),
            bloccoId: blocco.id, estratto: String(blocco.text.prefix(300)), nota: nota,
            consultatoIl: letto.data, impronta: letto.impronta))
    }
}

private extension String {
    var nilSeVuoto: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
