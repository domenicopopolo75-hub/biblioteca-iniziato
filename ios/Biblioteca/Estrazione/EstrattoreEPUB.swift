import Foundation
import ZIPFoundation

/// EPUB 2/3: ordine dello spine, un blocco per paragrafo/titolo/voce; note (`aside`, epub:type footnote) marcate.
struct EstrattoreEPUB {
    func estrai(url: URL, sha256: String, linguaForzata: String?, titolo: String?) throws -> Pacchetto {
        let archivio: Archive
        do { archivio = try Archive(url: url, accessMode: .read, pathEncoding: nil) } catch { throw ErroreEstrazione.epub("archivio zip illeggibile") }

        func leggi(_ percorso: String) throws -> Data {
            guard let voce = archivio[percorso] else { throw ErroreEstrazione.epub("manca \(percorso)") }
            var dati = Data()
            _ = try archivio.extract(voce, skipCRC32: false) { dati.append($0) }
            return dati
        }

        let container = try leggi("META-INF/container.xml")
        guard let opfPath = XMLSemplice.attributo(in: container, elemento: "rootfile", attributo: "full-path") else {
            throw ErroreEstrazione.epub("container.xml senza rootfile")
        }
        let base = (opfPath as NSString).deletingLastPathComponent
        let opf = try leggi(opfPath)
        let parsed = OPF(dati: opf)
        let lingua = linguaForzata ?? parsed.lingua.map { String($0.prefix(2)) }

        var blocchi: [Blocco] = []
        var vuote: [Int] = []
        var ordine = 0
        var capitolo: String?
        for (i, idref) in parsed.spine.enumerated() {
            guard let href = parsed.manifest[idref] else { vuote.append(i); continue }
            let interno = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
            let percorso = (interno as NSString).standardizingPath.replacingOccurrences(of: "^/", with: "", options: .regularExpression)
            guard let dati = try? leggi(percorso.removingPercentEncoding ?? percorso) else { vuote.append(i); continue }
            let paragrafi = ParagrafiXHTML.estrai(dati)
            if paragrafi.isEmpty { vuote.append(i); continue }
            for (k, p) in paragrafi.enumerated() {
                let testo = Normalizza.testo(p.testo)
                guard !testo.isEmpty else { continue }
                if p.tipo == "heading" { capitolo = testo }
                blocchi.append(Blocco(id: String(format: "s%04d-b%04d", i, k), order: ordine, kind: p.tipo,
                                      locator: Locator(page_index: i, printed_page: nil, column: 0, bbox: nil,
                                                       chapter: capitolo, href: href),
                                      lang: Normalizza.scriptDominante(testo) ?? lingua, text_raw: p.testo, text: testo))
                ordine += 1
            }
        }
        let n = parsed.spine.count
        return Pacchetto(
            generated_at: ISO8601DateFormatter().string(from: Date()),
            generator: .init(name: "ios", version: "0.1.0"),
            work: .init(title: titolo ?? parsed.titolo ?? url.deletingPathExtension().lastPathComponent,
                        author: parsed.autore, language: lingua),
            edition: .init(id: "sha256:\(sha256)", source_file: url.lastPathComponent, source_sha256: sha256,
                           format: "epub", provenance: nil, pages_total: n),
            coverage: .init(units_total: n, units_with_text: n - vuote.count, units_empty: vuote,
                            units_need_ocr: [], excluded_repeated: nil, units_ocr: nil),
            blocks: blocchi)
    }
}

/// Lettura minima dell'OPF con XMLParser.
private final class OPF: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    var titolo: String?, autore: String?, lingua: String?
    private var campo: String?
    private var buffer = ""

    init(dati: Data) {
        super.init()
        let p = XMLParser(data: dati)
        p.shouldProcessNamespaces = true
        p.delegate = self
        p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch el {
        case "item": if let id = a["id"], let href = a["href"] { manifest[id] = href }
        case "itemref": if let id = a["idref"] { spine.append(id) }
        case "title", "creator", "language": campo = el; buffer = ""
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if campo != nil { buffer += s } }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        guard el == campo else { return }
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty {
            switch el {
            case "title": titolo = titolo ?? v
            case "creator": autore = autore ?? v
            case "language": lingua = lingua ?? v
            default: break
            }
        }
        campo = nil
    }
}

enum XMLSemplice {
    static func attributo(in dati: Data, elemento: String, attributo: String) -> String? {
        final class D: NSObject, XMLParserDelegate {
            let el: String, at: String; var valore: String?
            init(_ e: String, _ a: String) { el = e; at = a }
            func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if e == el, valore == nil { valore = a[at] }
            }
        }
        let d = D(elemento, attributo)
        let p = XMLParser(data: dati)
        p.shouldProcessNamespaces = true
        p.delegate = d
        p.parse()
        return d.valore
    }
}

/// Paragrafi da XHTML. XMLParser se il file è XML valido; altrimenti ripiego con espressioni regolari.
enum ParagrafiXHTML {
    struct Paragrafo { var tipo: String; var testo: String }

    static let blocchi: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre",
                                       "dd", "dt", "figcaption", "td", "th"]
    static let titoli: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    static func estrai(_ dati: Data) -> [Paragrafo] {
        let d = Delegato()
        let p = XMLParser(data: dati)
        p.shouldProcessNamespaces = true
        p.shouldReportNamespacePrefixes = false
        p.delegate = d
        if p.parse() { d.chiudi(); return d.out }
        return ripiego(String(decoding: dati, as: UTF8.self))
    }

    private final class Delegato: NSObject, XMLParserDelegate {
        var out: [Paragrafo] = []
        var buf = ""
        var tipo = "paragraph"
        var salta = 0
        var nota = 0

        func chiudi() {
            if !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Paragrafo(tipo: nota > 0 && tipo != "heading" ? "note" : tipo, testo: buf))
            }
            buf = ""; tipo = "paragraph"
        }
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
            if ["script", "style", "head"].contains(e) { salta += 1 }
            if e == "br" { buf += "\n"; return }
            if blocchi.contains(e) || ["div", "section", "aside"].contains(e) {
                chiudi()
                if titoli.contains(e) { tipo = "heading" }
                let t = (a["type"] ?? "") + " " + (a["epub:type"] ?? "") + " " + (a["class"] ?? "")
                if e == "aside" || t.contains("footnote") || t.contains("endnote") { nota += 1 }
            }
        }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if ["script", "style", "head"].contains(e) { salta = max(0, salta - 1) }
            if blocchi.contains(e) || ["div", "section", "aside", "body"].contains(e) {
                chiudi()
                if e == "aside", nota > 0 { nota -= 1 }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if salta == 0 { buf += s } }
    }

    static func ripiego(_ html: String) -> [Paragrafo] {
        var s = html.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<(h[1-6])[^>]*>", with: "\u{1}\u{2}", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</?(p|div|li|h[1-6]|blockquote|section|br)[^>]*>", with: "\u{1}", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return s.components(separatedBy: "\u{1}").compactMap { pezzo in
            let titolo = pezzo.hasPrefix("\u{2}")
            let t = titolo ? String(pezzo.dropFirst()) : pezzo
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Paragrafo(tipo: titolo ? "heading" : "paragraph", testo: t)
        }
    }
}
