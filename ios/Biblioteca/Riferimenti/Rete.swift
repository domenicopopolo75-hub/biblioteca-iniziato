import Foundation

/// Perché una fonte non ha dato il contenuto. Solo «scomparsa» e «negato» segnano la fonte come non raggiungibile:
/// un errore di rete passeggero non cambia lo stato di un riferimento.
enum ErroreFonte: LocalizedError, Equatable {
    case scomparsa(Int)
    case negato(Int)
    case rete(String)
    case troppoGrande(Int64)
    case nonConsultabile(String)
    case robots

    var errorDescription: String? {
        switch self {
        case .scomparsa(let c): return "La pagina non esiste più (risposta \(c))."
        case .negato(let c): return "La fonte nega l'accesso (risposta \(c))."
        case .rete(let m): return "Fonte non raggiungibile: \(m)"
        case .troppoGrande(let b):
            return "Il file è troppo grande per la memoria temporanea (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)))."
        case .nonConsultabile(let m): return m
        case .robots: return "Il sito chiede di non essere letto in modo automatico (robots.txt)."
        }
    }

    var fonteNonRaggiungibile: Bool {
        switch self {
        case .scomparsa, .negato, .robots: return true
        default: return false
        }
    }
}

/// Recupero di dati dal web. Dietro un'interfaccia per poterlo provare senza rete.
protocol Scaricatore: Sendable {
    func dati(_ url: URL, massimoByte: Int64) async throws -> (dati: Data, tipo: String?)
}

/// Rete reale: rispetta robots.txt, ha timeout, e rifiuta file oltre il limite prima di scaricarli quando il sito lo dichiara.
struct ReteWeb: Scaricatore {
    static let agente = "BibliotecaIniziato/0.2 (uso personale, lettura su richiesta)"
    let robots = RegoleRobots()

    func dati(_ url: URL, massimoByte: Int64) async throws -> (dati: Data, tipo: String?) {
        guard await robots.consente(url) else { throw ErroreFonte.robots }
        // Dimensione dichiarata: se già nota e troppo grande, non si scarica.
        var testa = URLRequest(url: url)
        testa.httpMethod = "HEAD"
        testa.timeoutInterval = 15
        testa.setValue(Self.agente, forHTTPHeaderField: "User-Agent")
        if let (_, r) = try? await URLSession.shared.data(for: testa), let h = r as? HTTPURLResponse,
           h.statusCode < 300, h.expectedContentLength > massimoByte {
            throw ErroreFonte.troppoGrande(h.expectedContentLength)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 45
        req.setValue(Self.agente, forHTTPHeaderField: "User-Agent")
        let tmp: URL, risposta: URLResponse
        do { (tmp, risposta) = try await URLSession.shared.download(for: req) } catch {
            throw ErroreFonte.rete(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let h = risposta as? HTTPURLResponse else { throw ErroreFonte.rete("risposta non valida") }
        switch h.statusCode {
        case 200..<300: break
        case 404, 410: throw ErroreFonte.scomparsa(h.statusCode)
        case 401, 403, 451: throw ErroreFonte.negato(h.statusCode)
        default: throw ErroreFonte.rete("risposta \(h.statusCode)")
        }
        let dim = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if dim > massimoByte { throw ErroreFonte.troppoGrande(dim) }
        return (try Data(contentsOf: tmp), h.mimeType)
    }
}

/// robots.txt: gruppo `User-agent: *`, prefissi Disallow/Allow, vince la regola più specifica.
actor RegoleRobots {
    private var per: [String: String] = [:]

    func consente(_ url: URL) async -> Bool {
        guard let host = url.host, let schema = url.scheme else { return true }
        let chiave = "\(schema)://\(host)"
        if per[chiave] == nil {
            var req = URLRequest(url: URL(string: chiave + "/robots.txt")!)
            req.timeoutInterval = 10
            req.setValue(ReteWeb.agente, forHTTPHeaderField: "User-Agent")
            if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 {
                per[chiave] = String(data: d, encoding: .utf8) ?? ""
            } else {
                per[chiave] = ""   // nessun robots.txt raggiungibile: consentito, come fa il servizio
            }
        }
        let p = url.path.isEmpty ? "/" : url.path
        return Self.consente(testo: per[chiave] ?? "", percorso: p)
    }

    nonisolated static func consente(testo: String, percorso: String) -> Bool {
        var gruppoGenerale = false
        var inizioGruppo = true
        var regole: [(Bool, String)] = []
        for riga in testo.components(separatedBy: .newlines) {
            let r = riga.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let due = r.firstIndex(of: ":") else { continue }
            let chiave = r[..<due].lowercased().trimmingCharacters(in: .whitespaces)
            let valore = r[r.index(after: due)...].trimmingCharacters(in: .whitespaces)
            switch chiave {
            case "user-agent":
                if inizioGruppo { gruppoGenerale = false }
                if valore == "*" { gruppoGenerale = true }
                inizioGruppo = false
            case "disallow", "allow":
                inizioGruppo = true
                if gruppoGenerale, !valore.isEmpty { regole.append((chiave == "allow", valore)) }
            default: break
            }
        }
        var migliore: (Bool, Int)?
        for (permette, prefisso) in regole where percorso.hasPrefix(prefisso.replacingOccurrences(of: "*", with: "")) {
            if migliore == nil || prefisso.count > migliore!.1 { migliore = (permette, prefisso.count) }
        }
        return migliore?.0 ?? true
    }
}
