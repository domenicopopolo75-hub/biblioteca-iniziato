import AVFoundation
import UIKit
import XCTest
import ZIPFoundation
@testable import Biblioteca

final class NormalizzaTests: XCTestCase {
    func testStessiCasiDelPython() {
        XCTAssertEqual(Normalizza.testo("ﬁne e ﬂusso"), "fine e flusso")
        XCTAssertEqual(Normalizza.testo("Nord-\nEst"), "Nord- Est")
        XCTAssertEqual(Normalizza.testo("parola  con\u{00A0}spazi"), "parola con spazi")
        XCTAssertEqual(Normalizza.testo("equili-\nbrio degli\nopposti"), "equilibrio degli opposti")
    }

    func testScript() {
        XCTAssertEqual(Normalizza.scriptDominante("כַּטַל־חֶרְמוֹן 3"), "he")
        XCTAssertEqual(Normalizza.scriptDominante("λόγος"), "el")
        XCTAssertNil(Normalizza.scriptDominante("Logos"))
    }

    func testSegmentiVoceRispettanoLeFrasi() {
        let t = String(repeating: "Questa è una frase di prova abbastanza lunga. ", count: 20)
        let s = Normalizza.segmentiVoce(t, massimo: 200)
        XCTAssertGreaterThan(s.count, 3)
        XCTAssertTrue(s.allSatisfy { $0.count <= 200 && $0.hasSuffix(".") })
        XCTAssertEqual(s.joined(separator: " "), t.trimmingCharacters(in: .whitespaces))
    }
}

final class EstrazioneTests: XCTestCase {
    let sx = ["Sinistra uno: primo paragrafo della colonna sinistra.",
              "Sinistra due: secondo paragrafo della colonna sinistra.",
              "Sinistra tre: ultimo paragrafo della colonna sinistra."]
    let dx = ["Destra uno: primo paragrafo della colonna destra.",
              "Destra due: ultimo paragrafo della colonna destra."]

    func pdfDueColonne(pagine: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("colonne-\(UUID()).pdf")
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let corpo: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        try r.writePDF(to: url) { ctx in
            for n in 0..<pagine {
                ctx.beginPage()
                ("Rivista di prova" as NSString).draw(at: CGPoint(x: 200, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                ("\(n + 1)" as NSString).draw(at: CGPoint(x: 290, y: 44), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                ("Titolo largo pagina \(n + 1) che attraversa il centro" as NSString)
                    .draw(in: CGRect(x: 40, y: 80, width: 515, height: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
                ("Ordine di prova" as NSString).draw(at: CGPoint(x: 40, y: 810), withAttributes: [.font: UIFont.systemFont(ofSize: 8)])
                // colonna destra disegnata per prima: l'ordine deve venire dalla geometria
                for (i, t) in dx.enumerated() { (t as NSString).draw(in: CGRect(x: 310, y: 150 + i * 100, width: 245, height: 80), withAttributes: corpo) }
                for (i, t) in sx.enumerated() { (t as NSString).draw(in: CGRect(x: 40, y: 150 + i * 100, width: 245, height: 80), withAttributes: corpo) }
            }
        }
        return url
    }

    func testPDFOrdineColonneEMargini() throws {
        let url = try pdfDueColonne()
        let p = try EstrattorePDF(ocrAbilitato: false).estrai(url: url, sha256: "x", lingua: "it", titolo: nil)
        let pagina0 = p.blocks.filter { $0.locator.page_index == 0 }.map(\.text)
        XCTAssertEqual(pagina0, ["Titolo largo pagina 1 che attraversa il centro"] + sx + dx)
        XCTAssertFalse(p.blocks.contains { $0.text.contains("Rivista di prova") || $0.text.contains("Ordine di prova") })
        XCTAssertEqual(Set(p.blocks.filter { $0.locator.page_index == 2 }.map(\.locator.printed_page)), ["3"])
        XCTAssertEqual(p.blocks.map(\.order), Array(0..<p.blocks.count))
        XCTAssertEqual(p.blocks.first?.kind, "heading")
        XCTAssertEqual(p.coverage.units_with_text, 4)
    }

    func testEPUBOrdineSpineENote() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("libro-\(UUID()).epub")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        func aggiungi(_ percorso: String, _ s: String) throws {
            let d = Data(s.utf8)
            try a.addEntry(with: percorso, type: .file, uncompressedSize: Int64(d.count)) { pos, size in
                d.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        try aggiungi("mimetype", "application/epub+zip")
        try aggiungi("META-INF/container.xml", #"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)
        try aggiungi("OEBPS/content.opf", #"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test Book</dc:title><dc:creator>Anon</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c2"/><itemref idref="c1"/></spine></package>"#)
        try aggiungi("OEBPS/text/c1.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><h1>Chapter Two</h1><p>Second chapter text.</p><aside epub:type="footnote"><p>A footnote.</p></aside></body></html>"#)
        try aggiungi("OEBPS/text/c2.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>Chapter One</h1><p>First <i>chapter</i> text, with a hyphen-\nated word.</p></body></html>")
        let p = try EstrattoreEPUB().estrai(url: url, sha256: "y", linguaForzata: nil, titolo: nil)
        XCTAssertEqual(p.work.title, "Test Book")
        XCTAssertEqual(p.work.language, "en")
        XCTAssertEqual(p.blocks.map(\.text), ["Chapter One", "First chapter text, with a hyphenated word.",
                                              "Chapter Two", "Second chapter text.", "A footnote."])
        XCTAssertEqual(p.blocks.map(\.kind), ["heading", "paragraph", "heading", "paragraph", "note"])
        XCTAssertEqual(p.blocks[1].locator.chapter, "Chapter One")
        XCTAssertNil(p.blocks[0].locator.printed_page)
    }

    func testContrattoConLaPipelinePython() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "contratto", withExtension: "json"))
        let p = try JSONDecoder().decode(Pacchetto.self, from: Data(contentsOf: url))
        XCTAssertEqual(p.format, Pacchetto.formato)
        XCTAssertEqual(p.generator.name, "pipeline")
        XCTAssertFalse(p.blocks.isEmpty)
        XCTAssertEqual(p.blocks.map(\.order), Array(0..<p.blocks.count))
    }
}

@MainActor
final class LibreriaTests: XCTestCase {
    func testImportTXTEDeduplicaPerImpronta() async throws {
        let radice = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID())")
        let lib = Libreria(radice: radice)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("pupilla.txt")
        try "La pupilla del mondo\n\nPrimo paragrafo\nsu due righe.\n\nSecondo paragrafo.".write(to: f, atomically: true, encoding: .utf8)
        let a = await lib.importa(f)
        let b = await lib.importa(f)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertEqual(lib.libri.count, 1)
        let p = try XCTUnwrap(lib.pacchetto(a!.id))
        XCTAssertEqual(p.blocks.map(\.text), ["La pupilla del mondo", "Primo paragrafo su due righe.", "Secondo paragrafo."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.originale(a!).path))
        lib.salvaPosizione(Posizione(ordine: 2, segmento: 1, secondi: 3.5), per: a!.id)
        XCTAssertEqual(Libreria(radice: radice).posizione(a!.id).ordine, 2, "la posizione sopravvive al riavvio")
    }

    func testArchivioTraduzioniInvalidaSeCambiaIlTesto() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let arch = ArchivioTraduzioni(cartella: dir)
        var b = Blocco(id: "b1", order: 0, kind: "paragraph", locator: Locator(page_index: 0), lang: "en", text_raw: "x", text: "Will")
        await arch.registra(VoceTraduzione(testo: "Volontà", motore: "test", versione: "1", data: Date(), linguaSorgente: "en",
                                           hashSorgente: ArchivioTraduzioni.hash(b.text)), per: b.id)
        await arch.salva()
        let riaperto = ArchivioTraduzioni(cartella: dir)
        let v = await riaperto.voce(b)
        XCTAssertEqual(v?.testo, "Volontà")
        b.text = "Will power"
        let nulla = await riaperto.voce(b)
        XCTAssertNil(nulla)
    }
}

final class VoceTests: XCTestCase {
    func testSintesiItalianaSuFile() async throws {
        let voce = SintetizzatoreFile.voceItaliana()
        try XCTSkipIf(voce == nil, "Nessuna voce italiana nel simulatore")
        let dir = FileManager.default.temporaryDirectory
        let s = SintetizzatoreFile()
        let (url, durata) = try await s.scrivi("Equilibrio degli opposti e Tempio.", voce: voce, url: dir.appendingPathComponent("prova-\(UUID()).m4a"))
        XCTAssertGreaterThan(durata, 0.5)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(Double(file.length) / file.fileFormat.sampleRate, 0.5)
        // seconda frase subito dopo: verifica che le chiamate in sequenza non si chiudano a vicenda
        let (_, d2) = try await s.scrivi("Seconda frase.", voce: voce, url: dir.appendingPathComponent("prova-\(UUID()).m4a"))
        XCTAssertGreaterThan(d2, 0.3)
    }
}

final class StudioTests: XCTestCase {
    func testIndiceFTS5TrovaParoleEDeclinazioni() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("indice-\(UUID()).sqlite")
        let i = Indice(percorso: u)
        XCTAssertTrue(i.disponibile, "FTS5 deve essere disponibile nel SQLite di iOS")
        let blocchi = ["L'equilibrio degli opposti nel Tempio.", "Of Equilibrium: the balance of opposites.", "La volontà dell'iniziato."].enumerated().map {
            Blocco(id: "b\($0.offset)", order: $0.offset, kind: "paragraph", locator: Locator(page_index: $0.offset), lang: nil, text_raw: $0.element, text: $0.element)
        }
        i.indicizza(libro: "L1", blocchi: blocchi)
        XCTAssertTrue(i.contiene(libro: "L1"))
        XCTAssertEqual(Set(i.cerca(["equilibri"]).map(\.ordine)), [0, 1], "il prefisso copre equilibrio/equilibrium")
        XCTAssertEqual(i.cerca(["volonta"]).first?.ordine, 2, "accenti ignorati")
        XCTAssertTrue(i.cerca(["tempio"], libri: ["ALTRO"]).isEmpty, "filtro per libro")
        i.rimuovi(libro: "L1")
        XCTAssertFalse(i.contiene(libro: "L1"))
    }

    func testSezioniDaiTitoliEConLimite() {
        var blocchi: [Blocco] = []
        func agg(_ kind: String, _ t: String, pagina: Int) {
            blocchi.append(Blocco(id: "b\(blocchi.count)", order: blocchi.count, kind: kind, locator: Locator(page_index: pagina), lang: "it", text_raw: t, text: t))
        }
        let lungo = String(repeating: "testo di prova ", count: 300)   // ~4500 caratteri
        agg("heading", "Capitolo primo", pagina: 0); agg("paragraph", lungo, pagina: 0); agg("paragraph", lungo, pagina: 1)
        agg("heading", "Capitolo secondo", pagina: 2); agg("paragraph", lungo, pagina: 2)
        let p = Pacchetto(generated_at: "", generator: .init(name: "t", version: "1"), work: .init(title: "T"),
                          edition: .init(id: "x", source_file: "x.pdf", source_sha256: "x", format: "pdf", pages_total: 3),
                          coverage: .init(units_total: 3, units_with_text: 3, units_empty: [], units_need_ocr: []), blocks: blocchi)
        let s = Studio.sezioni(di: p)
        XCTAssertEqual(s.map(\.titolo), ["Capitolo primo", "Capitolo secondo"])
        XCTAssertEqual(s.map(\.riferimento), ["pp. 1–2", "p. 3"])
        XCTAssertEqual(s.last?.a, blocchi.count - 1)
    }

    func testCostiEJSON() {
        XCTAssertEqual(ModelloClaude.haiku.costo(input: 50_000, output: 0), 0.005, accuracy: 1e-9, "fino a 100k: 0,10 $/M")
        XCTAssertEqual(ModelloClaude.haiku.costo(input: 200_000, output: 0), 0.10, accuracy: 1e-9, "oltre 100k il prezzo sale a 0,50 $/M")
        XCTAssertEqual(ModelloClaude.sonnet.costo(input: 10_000, output: 1_000), 0.03, accuracy: 1e-9)
        XCTAssertEqual(ClienteClaude.json([String].self, da: "Ecco:\n[\"uno\", \"due\"]\nfine"), ["uno", "due"])
        XCTAssertEqual(Data([0xfb, 0xff]).base64URL, "-_8")
    }
}
