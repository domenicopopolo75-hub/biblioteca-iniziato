import XCTest
@testable import Biblioteca

// MARK: doppioni di prova (nessuna rete, nessun account)

final class Contatore: @unchecked Sendable {
    private let blocco = NSLock()
    private var richieste: [String] = []
    func registra(_ u: String) { blocco.lock(); richieste.append(u); blocco.unlock() }
    var elenco: [String] { blocco.lock(); defer { blocco.unlock() }; return richieste }
}

/// Rete finta: risposte per prefisso di indirizzo, modificabili tra una chiamata e l'altra.
final class ReteFinta: Scaricatore, @unchecked Sendable {
    private let blocco = NSLock()
    private var risposte: [String: Result<Data, ErroreFonte>] = [:]
    let contatore = Contatore()

    func imposta(_ prefisso: String, _ testo: String) { imposta(prefisso, .success(Data(testo.utf8))) }
    func imposta(_ prefisso: String, _ r: Result<Data, ErroreFonte>) { blocco.lock(); risposte[prefisso] = r; blocco.unlock() }

    func dati(_ url: URL, massimoByte: Int64) async throws -> (dati: Data, tipo: String?) {
        contatore.registra(url.absoluteString)
        blocco.lock()
        let r = risposte.filter { url.absoluteString.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
        blocco.unlock()
        switch r {
        case .success(let d)?: return (d, nil)
        case .failure(let e)?: throw e
        case nil: throw ErroreFonte.rete("senza connessione (rete finta)")
        }
    }
}

@MainActor
final class DriveFinto: SorgenteDrive {
    var collegato = true
    var voci: [GoogleDrive.Voce] = []
    var contenuti: [String: Data] = [:]
    var scaricati: [String] = []

    func cerca(_ testo: String) async throws -> [GoogleDrive.Voce] { voci }
    func contenuto(_ v: GoogleDrive.Voce) async throws -> (dati: Data, nome: String) {
        scaricati.append(v.id)
        guard let d = contenuti[v.id] else { throw ErroreFonte.scomparsa(404) }
        return (d, v.name)
    }
}

enum Prova {
    static func articolo(titolo: String = "Sofia e il Pleroma", corpo: String = "La Sapienza discese") -> String {
        let lungo = String(repeating: "Il testo dell'articolo continua con parole sufficienti perché l'estrazione scelga l'articolo e non il contorno della pagina. ", count: 5)
        return """
        <!doctype html><html lang="it"><head><title>\(titolo) | Sito di prova</title>
        <meta property="og:title" content="\(titolo)"><meta name="author" content="Mario Rossi">
        <script>var x = "questo non è testo";</script><style>p { color: red }</style></head>
        <body><nav><a href="/">Home</a><a href="/contatti">Contatti</a></nav>
        <article><h1>\(titolo)</h1>
        <p>\(corpo) nella pienezza &amp; nell&#8217;ombra, e la luce la riconobbe come propria. \(lungo)</p>
        <h2>Seconda parte</h2><p>Secondo paragrafo dell'articolo di prova. \(lungo)</p></article>
        <footer>Copyright di prova</footer></body></html>
        """
    }

    static func risultatoEsterno(_ url: String = "https://paxpleroma.com/sofia-e-pleroma") -> Risultato {
        Risultato(id: Riferimento.identita(origine: .esterno, chiave: url), titolo: "Sofia e il Pleroma", origine: .esterno,
                  nomeFonte: "Pax Pleroma", collegamento: url, lingua: "it", formato: "html", accesso: .consultabile)
    }

    static func pacchetto(totali: Int, conTesto: Int, blocchi: Int = 2) -> Pacchetto {
        let bl = (0..<blocchi).map {
            Blocco(id: "b\($0)", order: $0, kind: "paragraph", locator: Locator(page_index: $0), lang: "it", text_raw: "x", text: "testo \($0)")
        }
        return Pacchetto(generated_at: "", generator: .init(name: "t", version: "1"),
                         work: .init(title: "T", author: nil, language: "it"),
                         edition: .init(id: "e", source_file: "f", source_sha256: "s", format: "pdf", provenance: nil, pages_total: totali),
                         coverage: .init(units_total: totali, units_with_text: conTesto, units_empty: [], units_need_ocr: [],
                                         excluded_repeated: nil, units_ocr: nil),
                         blocks: bl)
    }
}

/// Ambiente completo in una cartella temporanea.
@MainActor
struct Ambiente {
    let radice: URL
    let libreria: Libreria
    let registro: Registro
    let memoria: MemoriaTemporanea
    let rete: ReteFinta
    let drive: DriveFinto
    let consultazione: Consultazione

    init(radice: URL? = nil, limiteMemoria: Int64 = MemoriaTemporanea.limitePredefinito) {
        let r = radice ?? FileManager.default.temporaryDirectory.appendingPathComponent("amb-\(UUID())")
        self.radice = r
        libreria = Libreria(radice: r)
        registro = Registro(radice: r)
        memoria = MemoriaTemporanea(cartella: r.deletingLastPathComponent().appendingPathComponent("mem-\(UUID())"), limiteByte: limiteMemoria)
        let rete = ReteFinta(), drive = DriveFinto()
        self.rete = rete
        self.drive = drive
        consultazione = Consultazione(rete: rete, memoria: memoria, drive: drive, libreria: libreria, registro: registro)
    }
}

// MARK: estrazione HTML

final class EstrattoreHTMLTests: XCTestCase {
    func testArticoloSenzaContorno() {
        let a = EstrattoreHTML.estrai(Prova.articolo())
        XCTAssertEqual(a.titolo, "Sofia e il Pleroma")
        XCTAssertEqual(a.autore, "Mario Rossi")
        XCTAssertEqual(a.lingua, "it")
        let testo = a.blocchi.map(\.testo).joined(separator: "\n")
        XCTAssertFalse(testo.contains("non è testo"), "gli script non sono testo")
        XCTAssertFalse(testo.contains("Contatti"), "il menu non è articolo")
        XCTAssertFalse(testo.contains("Copyright"), "il piè di pagina non è articolo")
        XCTAssertTrue(testo.contains("pienezza & nell’ombra"), "le entità sono decodificate")
        XCTAssertTrue(a.blocchi.contains { $0.eTitolo && $0.testo == "Seconda parte" })
    }

    func testAutoreAssenteNonVieneInventato() {
        let a = EstrattoreHTML.estrai("<html><head><title>Solo titolo</title></head><body><article><p>\(String(repeating: "parole di prova ", count: 40))</p></article></body></html>")
        XCTAssertNil(a.autore)
        XCTAssertEqual(a.titolo, "Solo titolo")
    }

    func testImportatoreAccettaHTMLeDeduplica() async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID()).html")
        try Prova.articolo().write(to: f, atomically: true, encoding: .utf8)
        let sha = try Importatore.sha256(f)
        let p = try Importatore.pacchetto(per: f, sha: sha, indirizzo: "https://paxpleroma.com/sofia")
        XCTAssertEqual(p.edition.format, "html")
        XCTAssertEqual(p.edition.provenance, "https://paxpleroma.com/sofia")
        XCTAssertEqual(p.work.title, "Sofia e il Pleroma")
        XCTAssertEqual(LivelloLettura.per(pacchetto: p), .completo)
        XCTAssertTrue(p.blocks.allSatisfy { $0.locator.href == "https://paxpleroma.com/sofia" })
    }
}

// MARK: livelli di lettura

final class LivelloTests: XCTestCase {
    func testIlSoloCollegamentoNonEUnaLettura() {
        let r = Prova.risultatoEsterno().comeRiferimento()
        XCTAssertEqual(r.livello, .riferimento)
        XCTAssertNil(r.impronta)
        XCTAssertNil(r.ultimaConsultazione)
    }

    func testLivelloDalTestoElaborato() {
        XCTAssertEqual(LivelloLettura.per(pacchetto: Prova.pacchetto(totali: 3, conTesto: 3)), .completo)
        XCTAssertEqual(LivelloLettura.per(pacchetto: Prova.pacchetto(totali: 3, conTesto: 2)), .parziale)
        XCTAssertEqual(LivelloLettura.per(pacchetto: Prova.pacchetto(totali: 3, conTesto: 0, blocchi: 0)), .riferimento)
        XCTAssertLessThan(LivelloLettura.riferimento, .anteprima)
        XCTAssertLessThan(LivelloLettura.anteprima, .parziale)
        XCTAssertLessThan(LivelloLettura.parziale, .completo)
    }
}

// MARK: memoria temporanea

final class MemoriaTemporaneaTests: XCTestCase {
    func nuova(_ limite: Int64) -> MemoriaTemporanea {
        MemoriaTemporanea(cartella: FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID())"), limiteByte: limite)
    }

    func testLimiteScartaLeVociMenoRecenti() {
        let m = nuova(1000)
        m.scrivi(Data(count: 400), chiave: "a")
        Thread.sleep(forTimeInterval: 0.05)
        m.scrivi(Data(count: 400), chiave: "b")
        Thread.sleep(forTimeInterval: 0.05)
        m.scrivi(Data(count: 400), chiave: "c")
        XCTAssertLessThanOrEqual(m.occupazione, 1000)
        XCTAssertNil(m.leggi("a"), "la voce più vecchia è stata scartata")
        XCTAssertNotNil(m.leggi("c"))
    }

    func testContenutoOltreIlLimiteNonVieneTenuto() {
        let m = nuova(1000)
        XCTAssertFalse(m.scrivi(Data(count: 5000), chiave: "grande"))
        XCTAssertEqual(m.numeroVoci, 0)
    }

    func testSvuota() {
        let m = nuova(10_000)
        m.scrivi(Data(count: 100), chiave: "x")
        XCTAssertGreaterThan(m.occupazione, 0)
        m.svuota()
        XCTAssertEqual(m.occupazione, 0)
        XCTAssertNil(m.leggi("x"))
        XCTAssertTrue(m.scrivi(Data(count: 10), chiave: "y"), "dopo lo svuotamento la memoria è di nuovo utilizzabile")
    }

    func testVoceScadutaNonVieneRestituita() {
        let m = nuova(10_000)
        m.scrivi(Data(count: 10), chiave: "x")
        XCTAssertNotNil(m.leggi("x", eta: 60))
        XCTAssertNil(m.leggi("x", eta: -1))
    }
}

// MARK: registro, consultazione, copia

@MainActor
final class RiferimentiTests: XCTestCase {
    func testRiferimentoSalvatoSiRitrovaDopoIlRiavvioSenzaCopiaPermanente() throws {
        let a = Ambiente()
        a.registro.salva(Prova.risultatoEsterno().comeRiferimento())
        let riavviato = Registro(radice: a.radice)
        XCTAssertEqual(riavviato.riferimenti.count, 1)
        XCTAssertEqual(riavviato.riferimenti.first?.collegamento, "https://paxpleroma.com/sofia-e-pleroma")
        XCTAssertTrue(a.libreria.libri.isEmpty, "salvare un riferimento non crea libri")
        let voci = try FileManager.default.contentsOfDirectory(at: a.radice, includingPropertiesForKeys: [.isDirectoryKey])
        XCTAssertTrue(voci.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true },
                      "nessuna cartella di contenuto: solo file di catalogo")
        XCTAssertTrue(a.rete.contatore.elenco.isEmpty, "salvare non scarica nulla")
    }

    func testSalvareDueVolteNonDuplicaENonAzzeraIDati() {
        let a = Ambiente()
        var r = Prova.risultatoEsterno().comeRiferimento()
        r.livello = .completo
        r.copiaId = "libro1"
        a.registro.salva(r)
        a.registro.salva(Prova.risultatoEsterno().comeRiferimento())
        XCTAssertEqual(a.registro.riferimenti.count, 1)
        XCTAssertEqual(a.registro.riferimenti[0].livello, .completo)
    }

    func testConsultaArticoloSenzaCreareCopie() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let letto = try await a.consultazione.leggi(r)
        XCTAssertEqual(letto.livello, .completo)
        XCTAssertGreaterThanOrEqual(letto.pacchetto.blocks.count, 3)
        XCTAssertTrue(a.libreria.libri.isEmpty, "consultare non conserva")
        XCTAssertTrue(a.registro.riferimenti.isEmpty, "consultare non salva da sola il riferimento")
        XCTAssertEqual(a.memoria.numeroVoci, 1, "il testo è in memoria temporanea")
        a.consultazione.salvaRiferimento(r, letto: letto)
        let salvato = try XCTUnwrap(a.registro.trova(r.id))
        XCTAssertEqual(salvato.livello, .completo)
        XCTAssertNotNil(salvato.ultimaConsultazione)
        XCTAssertNil(salvato.copiaId)
        XCTAssertTrue(a.libreria.libri.isEmpty, "salvare il riferimento non crea una copia")
    }

    func testMaterialeNonAccessibileRestaRiferimentoSenzaFingereLettura() async throws {
        let a = Ambiente()
        a.rete.imposta("https://sito.example/libro", .failure(.negato(403)))
        var r = Prova.risultatoEsterno("https://sito.example/libro")
        r.formato = "pdf"
        do { _ = try await a.consultazione.leggi(r); XCTFail("doveva fallire") } catch {}
        let rif = a.consultazione.salvaRiferimento(r)
        XCTAssertEqual(rif.livello, .riferimento)
        XCTAssertNil(rif.ultimaConsultazione)
        XCTAssertNil(rif.impronta)
        // solo collegamento (formato non leggibile): resta riferimento
        var d = Prova.risultatoEsterno("https://sito.example/scheda")
        d.accesso = .soloCollegamento
        let s = a.consultazione.salvaRiferimento(d)
        XCTAssertEqual(s.livello, .riferimento)
        XCTAssertEqual(s.testoDisponibile, false)
    }

    func testAnteprimaDiRicercaNonContaComeLettura() {
        let a = Ambiente()
        var r = Prova.risultatoEsterno()
        r.anteprima = "Un estratto di due righe dalla ricerca."
        XCTAssertEqual(a.consultazione.salvaRiferimento(r).livello, .riferimento)
    }

    func testConservazioneEsplicitaSenzaDuplicati() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let primo = try await a.consultazione.conserva(r)
        XCTAssertEqual(a.libreria.libri.count, 1)
        XCTAssertEqual(primo.provenienza, "https://paxpleroma.com/sofia-e-pleroma")
        // la pagina cambia (altro contenuto, altro hash): il secondo tentativo non crea un secondo libro
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo(corpo: "Testo diverso"))
        let secondo = try await a.consultazione.conserva(r)
        XCTAssertEqual(secondo.id, primo.id)
        XCTAssertEqual(a.libreria.libri.count, 1)
        // anche se il registro viene perso, la provenienza riconosce la copia già fatta
        a.registro.elimina(r.id)
        let terzo = try await a.consultazione.conserva(r)
        XCTAssertEqual(terzo.id, primo.id)
        XCTAssertEqual(a.libreria.libri.count, 1)
        XCTAssertEqual(a.registro.trova(r.id)?.copiaId, primo.id)
    }

    func testSvuotareLaMemoriaTemporaneaPreservaTutto() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let letto = try await a.consultazione.leggi(r)
        _ = try await a.consultazione.conserva(r)
        a.consultazione.aggiungiAppunto(r, letto: letto, blocco: letto.pacchetto.blocks[1], nota: "da ricordare")
        XCTAssertGreaterThan(a.memoria.numeroVoci, 0)
        a.memoria.svuota()
        XCTAssertEqual(a.memoria.numeroVoci, 0)
        XCTAssertEqual(a.libreria.libri.count, 1, "la copia volontaria resta")
        let riaperto = Registro(radice: a.radice)
        XCTAssertEqual(riaperto.riferimenti.count, 1, "il riferimento resta")
        XCTAssertEqual(riaperto.appunti.count, 1, "l'appunto resta")
        XCTAssertEqual(riaperto.appunti[0].estratto.isEmpty, false)
        XCTAssertNotNil(riaperto.appunti[0].impronta, "l'appunto conserva la versione consultata")
        XCTAssertFalse(riaperto.appunti[0].passaggio.isEmpty, "e il riferimento al passaggio")
    }

    func testFonteCambiataSegnalataEAppuntiNonPersi() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let letto = try await a.consultazione.leggi(r)
        a.consultazione.aggiungiAppunto(r, letto: letto, blocco: letto.pacchetto.blocks[0], nota: "primo appunto")
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo(corpo: "Un testo completamente riscritto"))
        _ = try await a.consultazione.leggi(r, aggiorna: true)
        let rif = try XCTUnwrap(a.registro.trova(r.id))
        XCTAssertEqual(rif.stato, .cambiata)
        XCTAssertNotNil(rif.notaStato)
        XCTAssertEqual(a.registro.appunti(per: r.id).count, 1)
        XCTAssertNotEqual(a.registro.appunti(per: r.id)[0].impronta, rif.impronta, "l'appunto resta legato alla versione vista")
    }

    func testFonteScomparsaSegnalataSenzaPerdereNulla() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let letto = try await a.consultazione.leggi(r)
        a.consultazione.aggiungiAppunto(r, letto: letto, blocco: letto.pacchetto.blocks[0], nota: "nota")
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", .failure(.scomparsa(404)))
        do { _ = try await a.consultazione.leggi(r, aggiorna: true); XCTFail("doveva fallire") } catch {}
        let rif = try XCTUnwrap(a.registro.trova(r.id))
        XCTAssertEqual(rif.stato, .nonRaggiungibile)
        XCTAssertEqual(rif.livello, .completo, "ciò che era stato letto resta documentato")
        XCTAssertEqual(a.registro.appunti(per: r.id).count, 1)
    }

    func testErroreDiReteNonSegnaLaFonteComeScomparsa() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        _ = try await a.consultazione.leggi(r)
        a.consultazione.salvaRiferimento(r)
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", .failure(.rete("offline")))
        do { _ = try await a.consultazione.leggi(r, aggiorna: true) } catch {}
        XCTAssertNotEqual(a.registro.trova(r.id)?.stato, .nonRaggiungibile)
    }

    func testDriveConsultaEConservaSenzaDuplicati() async throws {
        let a = Ambiente()
        let testo = "Volontà e magia\n\nPrimo paragrafo del file su Drive.\n\nSecondo paragrafo del file su Drive."
        let voce = GoogleDrive.Voce(id: "ID123", name: "Appunti Kremmerz.txt", mimeType: "text/plain", size: "120",
                                    modifiedTime: "2026-11-01T10:00:00Z", webViewLink: "https://drive.google.com/file/d/ID123/view", md5Checksum: "abc")
        a.drive.contenuti["ID123"] = Data(testo.utf8)
        let r = Risultato(id: Riferimento.identita(origine: .drive, chiave: "ID123"), titolo: "Appunti Kremmerz", origine: .drive,
                          nomeFonte: "Google Drive", collegamento: voce.webViewLink!, formato: "txt", tipoMime: voce.mimeType,
                          accesso: .consultabile, identificativoRemoto: voce.id, versioneRemota: "abc")
        let letto = try await a.consultazione.leggi(r)
        XCTAssertEqual(letto.livello, .completo)
        XCTAssertTrue(a.libreria.libri.isEmpty)
        let uno = try await a.consultazione.conserva(r)
        let due = try await a.consultazione.conserva(r)
        XCTAssertEqual(uno.id, due.id)
        XCTAssertEqual(uno.provenienza, "drive:ID123")
        XCTAssertEqual(a.libreria.libri.count, 1)
        // lo stesso file importato dalla sfoglia di Drive viene riconosciuto (stesso contenuto)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("Appunti Kremmerz.txt")
        try testo.write(to: f, atomically: true, encoding: .utf8)
        let ancora = await a.libreria.importa(f)
        XCTAssertEqual(ancora?.id, uno.id)
        XCTAssertEqual(a.libreria.libri.count, 1)
    }

    func testEliminareIlRiferimentoChiedeEPortaViaGliAppunti() async throws {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        let r = Prova.risultatoEsterno()
        let letto = try await a.consultazione.leggi(r)
        a.consultazione.aggiungiAppunto(r, letto: letto, blocco: letto.pacchetto.blocks[0], nota: "nota")
        XCTAssertNotNil(a.registro.trova(r.id), "un appunto salva anche il riferimento")
        a.registro.elimina(r.id)
        XCTAssertNil(a.registro.trova(r.id))
        XCTAssertTrue(a.registro.appunti.isEmpty)
    }
}

// MARK: ricerca con provenienza

@MainActor
final class RicercaTests: XCTestCase {
    func testRisultatiDriveEOnlineConProvenienzaEFontiDichiarate() async throws {
        let a = Ambiente()
        a.drive.voci = [GoogleDrive.Voce(id: "D1", name: "Sofia gnostica.pdf", mimeType: "application/pdf", size: "1000",
                                         modifiedTime: nil, webViewLink: "https://drive.google.com/file/d/D1/view", md5Checksum: "m1")]
        a.rete.imposta("https://paxpleroma.com/sitemap.xml", """
        <urlset><url><loc>https://paxpleroma.com/sofia-e-pleroma</loc></url>
        <url><loc>https://www.paxpleroma.com/martinismo-pratica/</loc></url>
        <url><loc>https://paxpleroma.com/terms-and-conditions</loc></url></urlset>
        """)
        a.rete.imposta("https://paxpleroma.com/sofia-e-pleroma", Prova.articolo())
        a.rete.imposta("https://paxpleroma.com/martinismo-pratica", Prova.articolo(titolo: "Pratica martinista", corpo: "Il silenzio"))
        a.rete.imposta("https://www.liberaconoscenza.it/", .failure(.scomparsa(404)))
        let ricerca = Ricerca(libreria: a.libreria, drive: a.drive, online: RicercaOnline(rete: a.rete, memoria: a.memoria))
        await ricerca.cerca("sofia")

        let drive = ricerca.risultati.filter { $0.origine == .drive }
        let esterni = ricerca.risultati.filter { $0.origine == .esterno }
        XCTAssertEqual(drive.count, 1)
        XCTAssertEqual(drive[0].nomeFonte, "Google Drive")
        XCTAssertEqual(drive[0].identificativoRemoto, "D1")
        XCTAssertEqual(esterni.count, 1)
        XCTAssertEqual(esterni[0].nomeFonte, "Pax Pleroma")
        XCTAssertEqual(esterni[0].titolo, "Sofia e il Pleroma")
        XCTAssertFalse(esterni[0].titoloDaUrl, "il titolo viene dalla pagina")

        // tutte le 17 fonti del registro + telefono + Drive sono dichiarate, ciascuna con il suo stato
        XCTAssertEqual(ricerca.esiti.count, 2 + FontiOnline.elenco.count)
        func stato(_ id: String) -> Ricerca.EsitoFonte.Stato? { ricerca.esiti.first { $0.id == id }?.stato }
        XCTAssertEqual(stato("drive"), .interrogata(1))
        if case .interrogata(let n)? = stato("paxpleroma") { XCTAssertEqual(n, 1) } else { XCTFail("Pax Pleroma doveva essere interrogata") }
        if case .nonRaggiungibile? = stato("liberaconoscenza") {} else { XCTFail("fonte irraggiungibile da dichiarare") }
        if case .nonInterrogata? = stato("liberliber") {} else { XCTFail("fonte non supportata da dichiarare") }
        XCTAssertFalse(a.rete.contatore.elenco.contains { $0.contains("terms-and-conditions") }, "pagine escluse non lette")
        XCTAssertTrue(a.libreria.libri.isEmpty, "cercare non conserva nulla")
        XCTAssertTrue(a.registro.riferimenti.isEmpty)
    }

    func testDriveNonCollegatoEDichiaratoNonInterrogato() async {
        let a = Ambiente()
        a.drive.collegato = false
        let ricerca = Ricerca(libreria: a.libreria, drive: a.drive, online: RicercaOnline(rete: a.rete, memoria: a.memoria))
        await ricerca.cerca("sofia")
        if case .nonInterrogata? = ricerca.esiti.first(where: { $0.id == "drive" })?.stato {} else { XCTFail("Drive non collegato va dichiarato") }
        XCTAssertTrue(ricerca.risultati.filter { $0.origine == .drive }.isEmpty)
    }

    func testIlTitoloDaUrlEDichiaratoQuandoLaPaginaNonRisponde() async {
        let a = Ambiente()
        a.rete.imposta("https://paxpleroma.com/sitemap.xml", "<urlset><url><loc>https://paxpleroma.com/sofia-e-pleroma</loc></url></urlset>")
        let ricerca = Ricerca(libreria: a.libreria, drive: a.drive, online: RicercaOnline(rete: a.rete, memoria: a.memoria))
        await ricerca.cerca("sofia")
        let r = ricerca.risultati.first { $0.origine == .esterno }
        XCTAssertEqual(r?.titolo, "Sofia e pleroma")
        XCTAssertEqual(r?.titoloDaUrl, true)
        XCTAssertNil(r?.autore, "nessun metadato inventato")
    }

    func testRisultatiGiaSulTelefonoDistintiDaDriveEOnline() async throws {
        let a = Ambiente()
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sofia-\(UUID()).txt")
        try "Sofia nel Pleroma\n\nLa Sapienza e la luce, un paragrafo abbastanza lungo.".write(to: f, atomically: true, encoding: .utf8)
        _ = await a.libreria.importa(f)
        a.libreria.assicuraIndice()
        let ricerca = Ricerca(libreria: a.libreria, drive: a.drive, online: RicercaOnline(rete: a.rete, memoria: a.memoria))
        await ricerca.cerca("sapienza")
        XCTAssertEqual(ricerca.risultati.filter { $0.origine == .telefono }.count, 1)
    }

    func testAdattatorePaginaLink() async throws {
        let a = Ambiente()
        a.rete.imposta("https://www.otoitalia.it/liber-al.html", """
        <h3>Testi</h3><a href="/files/liber-al-vel-legis.pdf">Liber AL vel Legis (PDF)</a>
        <a href="/files/su-thelema.pdf">Download</a><a href="/altro.html">Altro</a>
        """)
        let o = RicercaOnline(rete: a.rete, memoria: a.memoria)
        let f = try XCTUnwrap(FontiOnline.elenco.first { $0.id == "otoitalia" })
        let e = try await o.cerca(f, "liber legis")
        XCTAssertEqual(e.risultati.count, 1)
        XCTAssertEqual(e.risultati[0].formato, "pdf")
        XCTAssertEqual(e.risultati[0].collegamento, "https://www.otoitalia.it/files/liber-al-vel-legis.pdf")
        XCTAssertEqual(e.risultati[0].lingua, "it")
        XCTAssertNil(e.risultati[0].autore)
    }

    func testAdattatoreInternetArchive() async throws {
        let a = Ambiente()
        a.rete.imposta("https://archive.org/advancedsearch.php", """
        {"response":{"docs":[{"identifier":"virginofworld00mead","title":"The Virgin of the World","creator":"G. R. S. Mead","language":"eng","description":"<p>Hermetic texts</p>"}]}}
        """)
        let o = RicercaOnline(rete: a.rete, memoria: a.memoria)
        let f = try XCTUnwrap(FontiOnline.elenco.first { $0.id == "archive" })
        let e = try await o.cerca(f, "virgin world")
        XCTAssertEqual(e.risultati.first?.identificativoRemoto, "virginofworld00mead")
        XCTAssertEqual(e.risultati.first?.lingua, "en")
        XCTAssertEqual(e.risultati.first?.collegamento, "https://archive.org/details/virginofworld00mead")
        XCTAssertEqual(e.risultati.first?.anteprima, "Hermetic texts")
    }
}

final class FontiETestiTests: XCTestCase {
    func testElencoFontiSpecchioDelRegistro() {
        XCTAssertEqual(FontiOnline.elenco.count, 17)
        XCTAssertEqual(Set(FontiOnline.supportate.map(\.id)), ["archive", "liberaconoscenza", "otoitalia", "genoalodge", "fuocosacro", "paxpleroma"])
        XCTAssertTrue(FontiOnline.escluse.allSatisfy { $0.motivo != nil }, "ogni fonte esclusa dichiara il motivo")
    }

    func testQueryDrivePiuParoleEApici() {
        let q = GoogleDrive.queryRicerca("Kremmerz l'uomo")
        XCTAssertTrue(q.contains("name contains 'Kremmerz' or fullText contains 'Kremmerz'"))
        XCTAssertTrue(q.contains("l\\'uomo"))
        XCTAssertTrue(q.hasSuffix("trashed = false"))
    }

    func testRobots() {
        let robots = "User-agent: Googlebot\nDisallow: /\n\nUser-agent: *\nDisallow: /privato\nAllow: /privato/pubblico\n"
        XCTAssertFalse(RegoleRobots.consente(testo: robots, percorso: "/privato/x"))
        XCTAssertTrue(RegoleRobots.consente(testo: robots, percorso: "/privato/pubblico/a"))
        XCTAssertTrue(RegoleRobots.consente(testo: robots, percorso: "/articolo"))
        XCTAssertTrue(RegoleRobots.consente(testo: "", percorso: "/qualsiasi"))
    }

    func testTerminiPiegatiESufficienza() {
        XCTAssertEqual(RicercaOnline.termini("Volontà e Magia"), ["volonta", "magia"])
        XCTAssertTrue(RicercaOnline.sufficiente(1, di: ["a", "b"]))
        XCTAssertFalse(RicercaOnline.sufficiente(1, di: ["a", "b", "c", "d"]))
    }
}
