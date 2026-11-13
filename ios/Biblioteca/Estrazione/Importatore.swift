import CryptoKit
import Foundation
import NaturalLanguage

/// Importazione: copia immutabile dell'originale + pacchetto a blocchi ordinati.
/// Accetta PDF, EPUB, TXT/MD e pacchetti `.bibl.json` prodotti da `pipeline/` (con originale facoltativo).
enum Importatore {
    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let dati = try h.read(upToCount: 1 << 20), !dati.isEmpty { hasher.update(data: dati) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func estraiTXT(url: URL, sha256: String, lingua: String?) throws -> Pacchetto {
        let dati = try Data(contentsOf: url)
        let testo = String(data: dati, encoding: .utf8) ?? String(data: dati, encoding: .windowsCP1252) ?? ""
        let pezzi = testo.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\n[ \\t]*\\n\\s*", with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lang = lingua ?? rilevaLingua(String(testo.prefix(4000)))
        let blocchi = pezzi.enumerated().map { (n, raw) -> Blocco in
            let t = Normalizza.testo(raw)
            let finale = t.last.map { ".:;,".contains($0) } ?? false
            let titolo = t.count < 80 && !finale && !raw.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n")
            return Blocco(id: String(format: "t0000-b%04d", n), order: n, kind: titolo ? "heading" : "paragraph",
                          locator: Locator(page_index: 0, printed_page: nil, column: 0, bbox: nil, chapter: nil, href: nil),
                          lang: Normalizza.scriptDominante(t) ?? lang, text_raw: raw, text: t)
        }
        return Pacchetto(generated_at: ISO8601DateFormatter().string(from: Date()),
                         generator: .init(name: "ios", version: "0.1.0"),
                         work: .init(title: url.deletingPathExtension().lastPathComponent, author: nil, language: lang),
                         edition: .init(id: "sha256:\(sha256)", source_file: url.lastPathComponent, source_sha256: sha256,
                                        format: "txt", provenance: nil, pages_total: 1),
                         coverage: .init(units_total: 1, units_with_text: blocchi.isEmpty ? 0 : 1,
                                         units_empty: blocchi.isEmpty ? [0] : [], units_need_ocr: [],
                                         excluded_repeated: nil, units_ocr: nil),
                         blocks: blocchi)
    }

    static func rilevaLingua(_ testo: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(testo)
        return r.dominantLanguage?.rawValue
    }

    /// Crea il pacchetto per un file. Non modifica mai l'originale.
    static func pacchetto(per url: URL, sha: String, lingua: String? = nil) throws -> Pacchetto {
        switch url.pathExtension.lowercased() {
        case "pdf":
            var p = try EstrattorePDF().estrai(url: url, sha256: sha, lingua: lingua, titolo: nil)
            if lingua == nil, let l = rilevaLingua(p.blocks.prefix(40).map(\.text).joined(separator: " ")) {
                p.work.language = l
                for i in p.blocks.indices where p.blocks[i].lang == nil { p.blocks[i].lang = l }
            }
            return p
        case "epub":
            var p = try EstrattoreEPUB().estrai(url: url, sha256: sha, linguaForzata: lingua, titolo: nil)
            if p.work.language == nil, let l = rilevaLingua(p.blocks.prefix(40).map(\.text).joined(separator: " ")) {
                p.work.language = l
                for i in p.blocks.indices where p.blocks[i].lang == nil { p.blocks[i].lang = l }
            }
            return p
        case "txt", "md", "text":
            return try estraiTXT(url: url, sha256: sha, lingua: lingua)
        case "json":
            let p = try JSONDecoder().decode(Pacchetto.self, from: Data(contentsOf: url))
            guard p.format == Pacchetto.formato else { throw ErroreEstrazione.formatoNonSupportato(p.format) }
            return p
        default:
            throw ErroreEstrazione.formatoNonSupportato(url.pathExtension)
        }
    }
}
