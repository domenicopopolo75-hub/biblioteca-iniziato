import Foundation

/// Una fonte online del registro (`servizio/servizio/fonti.json`) e ciò che l'app sa farne oggi.
struct DescrizioneFonte: Identifiable, Hashable {
    enum Metodo: String, Hashable {
        case sitemap       // articoli di un sito: mappa del sito (o link interni) + testo delle pagine
        case paginaLink    // pagina con collegamenti diretti a PDF/EPUB
        case archive       // Internet Archive: ricerca e file originale PDF/EPUB
    }

    var id: String
    var nome: String
    var url: String
    var metodo: Metodo?
    var lingua: String? = nil
    var escludi: [String] = []
    var motivo: String? = nil          // perché non è interrogata dall'app

    var supportata: Bool { metodo != nil }
}

enum FontiOnline {
    static let nonImplementata = "adattatore non ancora implementato"

    /// Specchio delle 17 fonti registrate nel servizio. Un test verifica che gli identificativi coincidano.
    static let elenco: [DescrizioneFonte] = [
        .init(id: "liberliber", nome: "Liber Liber", url: "https://liberliber.it/", metodo: nil, motivo: nonImplementata),
        .init(id: "wikisource-it", nome: "Wikisource italiana", url: "https://it.wikisource.org/", metodo: nil, motivo: nonImplementata),
        .init(id: "gutenberg", nome: "Project Gutenberg", url: "https://www.gutenberg.org/", metodo: nil,
              motivo: "catalogo troppo grande per il telefono: resta nella scansione mensile"),
        .init(id: "archive", nome: "Internet Archive", url: "https://archive.org/", metodo: .archive),
        .init(id: "gallica", nome: "Gallica / BnF", url: "https://gallica.bnf.fr/", metodo: nil, motivo: nonImplementata),
        .init(id: "e-rara", nome: "e-rara", url: "https://www.e-rara.ch/", metodo: nil, motivo: nonImplementata),
        .init(id: "mdz", nome: "MDZ / Biblioteca bavarese", url: "https://www.digitale-sammlungen.de/en/", metodo: nil, motivo: nonImplementata),
        .init(id: "liberaconoscenza", nome: "Libera Conoscenza",
              url: "https://www.liberaconoscenza.it/download/liberaconoscenza-download-libri.html", metodo: .paginaLink, lingua: "it"),
        .init(id: "rsarchive", nome: "Rudolf Steiner Archive", url: "https://rsarchive.org/", metodo: nil, motivo: nonImplementata),
        .init(id: "otoitalia", nome: "O.T.O. Italia", url: "https://www.otoitalia.it/liber-al.html", metodo: .paginaLink, lingua: "it"),
        .init(id: "hermetic", nome: "Hermetic Library", url: "https://hermetic.com/crowley/books/index?redirect=1", metodo: nil,
              motivo: "alcune pagine rispondono 403: accesso da provare con cautela"),
        .init(id: "sacred-texts", nome: "Sacred Texts", url: "https://sacred-texts.com/", metodo: nil, motivo: nonImplementata),
        .init(id: "iapsop", nome: "IAPSOP", url: "https://iapsop.com/", metodo: nil, motivo: nonImplementata),
        .init(id: "cintamani", nome: "Istituto Cintamani", url: "https://www.istitutocintamani.org/", metodo: nil, motivo: nonImplementata),
        .init(id: "genoalodge", nome: "Genoa Lodge 433", url: "https://genoalodge433.com/library", metodo: .paginaLink, lingua: "en"),
        .init(id: "fuocosacro", nome: "Fuoco Sacro", url: "https://www.fuocosacro.com/pagine/maestri/martinismo2.htm", metodo: .paginaLink, lingua: "it"),
        .init(id: "paxpleroma", nome: "Pax Pleroma", url: "https://paxpleroma.com/", metodo: .sitemap, lingua: "it", escludi: ["terms-and-conditions"]),
    ]

    static var supportate: [DescrizioneFonte] { elenco.filter(\.supportata) }
    static var escluse: [DescrizioneFonte] { elenco.filter { !$0.supportata } }
}

/// Ricerca nelle fonti online supportate. Ogni chiamata dichiara quanto ha davvero guardato.
struct RicercaOnline: Sendable {
    let rete: Scaricatore
    let memoria: MemoriaTemporanea
    var pagineDaLeggere = 20          // pagine di cui si legge il testo oltre a titolo e indirizzo
    var massimoPagina: Int64 = 2 * 1024 * 1024

    struct Esito { var risultati: [Risultato]; var dettaglio: String }

    static let esclusi = ["terms", "privacy", "cookie", "condizioni", "login", "cart", "wp-", "feed", "tag/", "category/"]

    func cerca(_ f: DescrizioneFonte, _ testo: String) async throws -> Esito {
        let t = Self.termini(testo)
        guard !t.isEmpty else { return Esito(risultati: [], dettaglio: "nessun termine di almeno 3 lettere") }
        switch f.metodo {
        case .sitemap?: return try await cercaSitemap(f, t)
        case .paginaLink?: return try await cercaPaginaLink(f, t)
        case .archive?: return try await cercaArchive(f, t)
        case nil: return Esito(risultati: [], dettaglio: f.motivo ?? "non supportata")
        }
    }

    // MARK: termini e punteggio

    static func piega(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func termini(_ s: String) -> [String] {
        var visti = Set<String>()
        return piega(s).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && visti.insert($0).inserted }
    }

    /// Quanti dei termini compaiono nel testo.
    static func punteggio(_ termini: [String], _ testo: String) -> Int {
        let p = piega(testo)
        return termini.filter { p.contains($0) }.count
    }

    static func sufficiente(_ punti: Int, di termini: [String]) -> Bool { punti >= max(1, (termini.count + 1) / 2) }

    // MARK: recupero con memoria temporanea

    func testo(_ url: URL, validita: TimeInterval = 24 * 3600) async throws -> String {
        if let c = memoria.leggi(url.absoluteString, eta: validita) { return EstrattoreHTML.decodifica(html: c.dati) }
        let (d, tipo) = try await rete.dati(url, massimoByte: massimoPagina)
        memoria.scrivi(d, chiave: url.absoluteString, tipo: tipo)
        return EstrattoreHTML.decodifica(html: d)
    }

    static func canonico(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host else { return url }
        let h = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        var p = c.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return "https://\(h)\(p.isEmpty ? "/" : p)"
    }

    static func titoloDaUrl(_ url: String) -> String {
        let slug = (URL(string: url)?.path ?? "").split(separator: "/").last.map(String.init) ?? ""
        let t = (slug.removingPercentEncoding ?? slug).replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? url : t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: sitemap (Pax Pleroma e siti simili)

    static func localizzazioni(_ xml: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<loc>\\s*([^<\\s]+)\\s*</loc>", options: [.caseInsensitive]) else { return [] }
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
            Range($0.range(at: 1), in: xml).map { String(xml[$0]).replacingOccurrences(of: "&amp;", with: "&") }
        }
    }

    static func linkInterni(_ html: String, base: URL) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"'#]+)", options: [.caseInsensitive]) else { return [] }
        let host = base.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html), let u = URL(string: String(html[r]), relativeTo: base)?.absoluteURL,
                  u.scheme?.hasPrefix("http") == true, u.query == nil,
                  u.host?.lowercased().replacingOccurrences(of: "www.", with: "") == host else { continue }
            out.append(u.absoluteString)
        }
        return out
    }

    func pagine(_ f: DescrizioneFonte) async throws -> (url: [String], metodo: String) {
        let base = URL(string: f.url)!
        let radice = "\(base.scheme ?? "https")://\(base.host ?? "")"
        do {
            let xml = try await testo(URL(string: radice + "/sitemap.xml")!)
            var tutte: [String] = []
            if xml.lowercased().contains("<sitemapindex") {
                for sotto in Self.localizzazioni(xml).prefix(6) {
                    if let u = URL(string: sotto), let x = try? await testo(u) { tutte += Self.localizzazioni(x) }
                }
            } else {
                tutte = Self.localizzazioni(xml)
            }
            if !tutte.isEmpty { return (tutte, "mappa del sito") }
        } catch let e as ErroreFonte where e == .robots { throw e }
        catch {}
        return (Self.linkInterni(try await testo(base), base: base), "link della pagina iniziale")
    }

    func cercaSitemap(_ f: DescrizioneFonte, _ termini: [String]) async throws -> Esito {
        let (elencoUrl, metodo) = try await pagine(f)
        var visti = Set<String>()
        var candidate: [String] = []
        let escludi = f.escludi + Self.esclusi
        for u in elencoUrl {
            let c = Self.canonico(u)
            let minuscolo = c.lowercased()
            guard visti.insert(c).inserted, !escludi.contains(where: { minuscolo.contains($0) }),
                  !minuscolo.hasSuffix("/home"), !minuscolo.hasSuffix("/index"),
                  URL(string: c)?.path.count ?? 0 > 1 else { continue }
            candidate.append(c)
        }
        var trovate: [(String, Int)] = []
        var altre: [String] = []
        for c in candidate {
            let p = Self.punteggio(termini, (URL(string: c)?.path ?? "").replacingOccurrences(of: "-", with: " "))
            if Self.sufficiente(p, di: termini) { trovate.append((c, p)) } else { altre.append(c) }
        }
        // Il testo delle pagine non trovate dal titolo si legge solo in parte: il limite è dichiarato.
        let daLeggere = Array(altre.prefix(pagineDaLeggere))
        var dalTesto: [(String, Int)] = []
        await withTaskGroup(of: (String, Int)?.self) { gruppo in
            for c in daLeggere {
                gruppo.addTask {
                    guard let u = URL(string: c), let h = try? await self.testo(u) else { return nil }
                    let a = EstrattoreHTML.estrai(h)
                    let p = Self.punteggio(termini, ([a.titolo ?? ""] + a.blocchi.map(\.testo)).joined(separator: " "))
                    return Self.sufficiente(p, di: termini) ? (c, p) : nil
                }
            }
            for await r in gruppo { if let r { dalTesto.append(r) } }
        }
        let ordinate = (trovate + dalTesto).sorted { $0.1 > $1.1 }.prefix(12)
        var risultati: [Risultato] = []
        for (c, _) in ordinate {
            var titolo = Self.titoloDaUrl(c), daUrl = true
            var autore: String?, lingua = f.lingua, anteprima: String?
            if let u = URL(string: c), let h = try? await testo(u) {
                let a = EstrattoreHTML.estrai(h)
                if let t = a.titolo, !t.isEmpty { titolo = t; daUrl = false }
                autore = a.autore
                lingua = a.lingua ?? f.lingua
                anteprima = a.blocchi.first { !$0.eTitolo && $0.testo.count >= 60 }.map { String($0.testo.prefix(240)) }
            }
            risultati.append(Risultato(id: Riferimento.identita(origine: .esterno, chiave: c), titolo: titolo, titoloDaUrl: daUrl,
                                       autore: autore, origine: .esterno, nomeFonte: f.nome, collegamento: c, lingua: lingua,
                                       formato: "html", accesso: .consultabile, anteprima: anteprima))
        }
        let dettaglio = "\(candidate.count) pagine nella \(metodo): titoli e indirizzi confrontati, testo letto in \(daLeggere.count)"
            + (altre.count > daLeggere.count ? " (altre \(altre.count - daLeggere.count) non lette)" : "")
        return Esito(risultati: risultati, dettaglio: dettaglio)
    }

    // MARK: pagine con collegamenti a PDF/EPUB

    static func collegamentiDiretti(_ html: String, base: URL) -> [(url: String, titolo: String)] {
        guard let re = try? NSRegularExpression(pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        var out: [(url: String, titolo: String)] = []
        var visti = Set<String>()
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r1 = Range(m.range(at: 1), in: html), let r2 = Range(m.range(at: 2), in: html),
                  let u = URL(string: String(html[r1]).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else { continue }
            let ext = u.pathExtension.lowercased()
            guard ["pdf", "epub"].contains(ext), visti.insert(u.absoluteString).inserted else { continue }
            var t = String(html[r2]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            t = EstrattoreHTML.decodificaEntita(t).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\((pdf|epub)\\)|\\b(download|scarica)\\b", with: " ", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–:()").union(.whitespaces))
            if t.count < 6 {
                let nome = (u.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "")
                    .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
                t = t.isEmpty ? nome : "\(nome) — \(t)"
            }
            out.append((u.absoluteString, t))
        }
        return out
    }

    func cercaPaginaLink(_ f: DescrizioneFonte, _ termini: [String]) async throws -> Esito {
        let base = URL(string: f.url)!
        let html = try await testo(base)
        let tutti = Self.collegamentiDiretti(html, base: base)
        let trovati = tutti.map { (e: $0, p: Self.punteggio(termini, $0.titolo + " " + $0.url)) }
            .filter { Self.sufficiente($0.p, di: termini) }.sorted { $0.p > $1.p }.prefix(12)
        let risultati = trovati.map { t in
            Risultato(id: Riferimento.identita(origine: .esterno, chiave: Self.canonico(t.e.url)), titolo: t.e.titolo,
                      origine: .esterno, nomeFonte: f.nome, collegamento: t.e.url, lingua: f.lingua,
                      formato: URL(string: t.e.url)?.pathExtension.lowercased(), accesso: .consultabile)
        }
        return Esito(risultati: Array(risultati), dettaglio: "pagina di elenco con \(tutti.count) PDF/EPUB: titoli e nomi dei file confrontati")
    }

    // MARK: Internet Archive

    static let lingue3: [String: String] = ["eng": "en", "ita": "it", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
                                            "spa": "es", "lat": "la", "grc": "el", "gre": "el", "heb": "he"]

    func cercaArchive(_ f: DescrizioneFonte, _ termini: [String]) async throws -> Esito {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        let q = "mediatype:texts AND (" + termini.map { "\($0)" }.joined(separator: " AND ") + ")"
        c.queryItems = [.init(name: "q", value: q), .init(name: "rows", value: "12"), .init(name: "output", value: "json"),
                        .init(name: "fl[]", value: "identifier"), .init(name: "fl[]", value: "title"),
                        .init(name: "fl[]", value: "creator"), .init(name: "fl[]", value: "language"),
                        .init(name: "fl[]", value: "description"), .init(name: "sort[]", value: "downloads desc")]
        let (d, _) = try await rete.dati(c.url!, massimoByte: 2 * 1024 * 1024)
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let docs = (j["response"] as? [String: Any])?["docs"] as? [[String: Any]] else {
            throw ErroreFonte.rete("risposta di Internet Archive non leggibile")
        }
        func primoTesto(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            if let a = v as? [String] { return a.first }
            return nil
        }
        let risultati: [Risultato] = docs.compactMap { doc in
            guard let ident = primoTesto(doc["identifier"]) else { return nil }
            let url = "https://archive.org/details/\(ident)"
            let descr = primoTesto(doc["description"]).map {
                EstrattoreHTML.decodificaEntita($0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
            return Risultato(id: Riferimento.identita(origine: .esterno, chiave: url), titolo: primoTesto(doc["title"]) ?? ident,
                             autore: primoTesto(doc["creator"]), origine: .esterno, nomeFonte: f.nome, collegamento: url,
                             lingua: primoTesto(doc["language"]).flatMap { Self.lingue3[$0.lowercased()] },
                             formato: nil, accesso: .consultabile, identificativoRemoto: ident, anteprima: descr)
        }
        return Esito(risultati: risultati, dettaglio: "ricerca sul catalogo di Internet Archive (testi), primi \(risultati.count) risultati")
    }
}
