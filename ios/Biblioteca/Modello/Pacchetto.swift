import Foundation

/// Contratto `biblioteca-pacchetto/1` (docs/FORMATO_PACCHETTO.md), condiviso con `pipeline/`.
struct Pacchetto: Codable, Equatable {
    static let formato = "biblioteca-pacchetto/1"

    var format: String = Pacchetto.formato
    var generated_at: String
    var generator: Generatore
    var work: Opera
    var edition: Edizione
    var coverage: Copertura
    var blocks: [Blocco]

    struct Generatore: Codable, Equatable { var name: String; var version: String }
    struct Opera: Codable, Equatable { var title: String; var author: String?; var language: String? }
    struct Edizione: Codable, Equatable {
        var id: String
        var source_file: String
        var source_sha256: String
        var format: String
        var provenance: String?
        var pages_total: Int
    }
    struct Copertura: Codable, Equatable {
        var units_total: Int
        var units_with_text: Int
        var units_empty: [Int]
        var units_need_ocr: [Int]
        var excluded_repeated: [String]?
        /// Pagine il cui testo viene da OCR (Vision): da segnalare come "testo riconosciuto".
        var units_ocr: [Int]?
    }
}

struct Blocco: Codable, Equatable, Identifiable {
    var id: String
    var order: Int
    var kind: String          // heading | paragraph | note
    var locator: Locator
    var lang: String?
    var text_raw: String
    var text: String

    var eNota: Bool { kind == "note" }
    var eTitolo: Bool { kind == "heading" }
}

struct Locator: Codable, Equatable {
    var page_index: Int
    var printed_page: String?
    var column: Int?
    var bbox: [Double]?
    var chapter: String?
    var href: String?

    /// Riferimento leggibile per le citazioni: pagina stampata se certa, altrimenti pagina fisica PDF.
    func descrizione(formato: String) -> String {
        switch formato {
        case "pdf":
            if let p = printed_page { return "p. \(p) (pag. PDF \(page_index + 1))" }
            return "pag. PDF \(page_index + 1)"
        case "epub":
            return [chapter, href].compactMap { $0 }.joined(separator: " · ")
        default:
            return "testo"
        }
    }
}
