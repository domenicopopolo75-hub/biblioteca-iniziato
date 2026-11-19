import Foundation

/// Articolo estratto da una pagina HTML: solo il testo dell'articolo, senza menu, script e contorno.
struct ArticoloHTML: Equatable {
    var titolo: String?
    var autore: String?
    var lingua: String?
    var canonico: String?
    var blocchi: [Parte]

    struct Parte: Equatable {
        var eTitolo: Bool
        var testo: String
    }

    var caratteri: Int { blocchi.reduce(0) { $0 + $1.testo.count } }
}

/// Estrattore senza dipendenze esterne. Non esegue JavaScript: una pagina che mostra il testo solo
/// dopo l'esecuzione di script dà un testo vuoto o corto, e il livello di lettura lo dichiara.
enum EstrattoreHTML {
    static func decodifica(html dati: Data) -> String {
        String(data: dati, encoding: .utf8) ?? String(data: dati, encoding: .windowsCP1252)
            ?? String(data: dati, encoding: .isoLatin1) ?? ""
    }

    static func estrai(_ html: String) -> ArticoloHTML {
        let titolo = meta(html, "og:title") ?? primo(html, "<title[^>]*>(.*?)</title>").map(pulisci)
            ?? primo(html, "<h1[^>]*>(.*?)</h1>").map { pulisci(togliTag($0)) }
        let autore = meta(html, "author") ?? meta(html, "article:author")
        let lingua = primo(html, "<html[^>]*\\blang\\s*=\\s*[\"']([A-Za-z-]+)").map { String($0.lowercased().prefix(2)) }
        let canonico = primo(html, "<link[^>]+rel\\s*=\\s*[\"']canonical[\"'][^>]*href\\s*=\\s*[\"']([^\"']+)")

        var corpo = sostituisci(html, "<!--.*?-->")
        corpo = sostituisci(corpo, "<(script|style|noscript|svg|iframe|form|nav|header|footer|aside|template|button|select)\\b[^>]*>.*?</\\1>")
        let radice = scegliRadice(corpo)

        var t = sostituisci(radice, "<h([1-6])\\b[^>]*>(.*?)</h\\1>", "\n\u{1}H\u{1}$2\n")
        t = sostituisci(t, "</?(p|div|section|article|main|li|ul|ol|blockquote|tr|td|th|br|table|figure|figcaption|pre|hr|dd|dt|dl)\\b[^>]*>", "\n")
        t = togliTag(t)
        t = decodificaEntita(t)

        var parti: [ArticoloHTML.Parte] = []
        for riga in t.components(separatedBy: "\n") {
            var r = riga
            var eTitolo = false
            if r.hasPrefix("\u{1}H\u{1}") { eTitolo = true; r = String(r.dropFirst(3)) }
            r = r.replacingOccurrences(of: "\u{1}", with: "")
            r = r.replacingOccurrences(of: "[ \\t\u{00A0}\u{2009}\u{202F}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.count >= 2 else { continue }
            if parti.last?.testo == r { continue }
            parti.append(.init(eTitolo: eTitolo, testo: r))
        }
        return ArticoloHTML(titolo: titolo.flatMap { $0.isEmpty ? nil : $0 }, autore: autore.map(pulisci),
                            lingua: lingua, canonico: canonico, blocchi: parti)
    }

    // MARK: strumenti

    private static func scegliRadice(_ s: String) -> String {
        for tag in ["article", "main", "body"] {
            for c in tutti(s, "<\(tag)\\b[^>]*>(.*?)</\(tag)>") where togliTag(c).count >= 400 { return c }
        }
        return s
    }

    private static func regex(_ p: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func sostituisci(_ s: String, _ p: String, _ con: String = "") -> String {
        guard let re = regex(p) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: con)
    }

    private static func primo(_ s: String, _ p: String) -> String? { tutti(s, p).first }

    private static func tutti(_ s: String, _ p: String, gruppo: Int = 1) -> [String] {
        guard let re = regex(p) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard m.numberOfRanges > gruppo, let r = Range(m.range(at: gruppo), in: s) else { return nil }
            return String(s[r])
        }
    }

    private static func togliTag(_ s: String) -> String { sostituisci(s, "<[^>]+>") }

    private static func pulisci(_ s: String) -> String {
        decodificaEntita(s).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Valore di un tag <meta name|property="nome" content="...">, con attributi in qualsiasi ordine.
    private static func meta(_ html: String, _ nome: String) -> String? {
        for tag in tutti(html, "(<meta\\b[^>]*>)") {
            var attributi: [String: String] = [:]
            for m in tutti(tag, "([A-Za-z:_-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*')", gruppo: 0) {
                guard let eq = m.firstIndex(of: "=") else { continue }
                let k = m[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let v = m[m.index(after: eq)...].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
                attributi[k] = String(v)
            }
            let chi = (attributi["property"] ?? attributi["name"] ?? "").lowercased()
            if chi == nome.lowercased(), let c = attributi["content"], !c.isEmpty { return pulisci(c) }
        }
        return nil
    }

    private static let entita: [String: String] = [
        "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "hellip": "…", "ndash": "–", "mdash": "—",
        "agrave": "à", "egrave": "è", "eacute": "é", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "Agrave": "À", "Egrave": "È", "Eacute": "É", "Igrave": "Ì", "Ograve": "Ò", "Ugrave": "Ù",
        "ccedil": "ç", "ntilde": "ñ", "uuml": "ü", "ouml": "ö", "auml": "ä", "acirc": "â", "ecirc": "ê",
        "deg": "°", "sect": "§", "middot": "·", "bull": "•", "copy": "©",
    ]

    static func decodificaEntita(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ms = re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed()
            for m in ms {
                guard let r = Range(m.range, in: t), let rg = Range(m.range(at: 2), in: t),
                      let rx = Range(m.range(at: 1), in: t) else { continue }
                let esadecimale = !t[rx].isEmpty
                if let n = UInt32(t[rg], radix: esadecimale ? 16 : 10), let u = Unicode.Scalar(n) {
                    t.replaceSubrange(r, with: String(Character(u)))
                }
            }
        }
        for (k, v) in entita { t = t.replacingOccurrences(of: "&\(k);", with: v) }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }
}
