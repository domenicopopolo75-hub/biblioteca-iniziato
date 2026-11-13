import Foundation

/// Modelli usati e prezzi in dollari per milione di token (listino Anthropic, novembre 2026).
/// Haiku 5.5: 0,10 / 0,50 fino a 100.000 token di prompt; oltre, 0,50 / 2,50. Sonnet 5.5: 2 / 10.
/// La spesa si conta in dollari e si confronta col budget in euro senza conversione: stima prudente
/// (1 $ < 1 €), quindi il tetto reale non viene mai superato.
enum ModelloClaude: String, Codable, CaseIterable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"

    var nome: String { self == .haiku ? "Haiku 5.5" : "Sonnet 5.5" }

    func costo(input: Int, output: Int) -> Double {
        switch self {
        case .haiku:
            let lungo = input > 100_000
            return Double(input) / 1e6 * (lungo ? 0.50 : 0.10) + Double(output) / 1e6 * (lungo ? 2.50 : 0.50)
        case .sonnet:
            return Double(input) / 1e6 * 2.0 + Double(output) / 1e6 * 10.0
        }
    }

    /// Stima grossolana prima di una chiamata: ~3,5 caratteri per token nei testi europei.
    static func tokenStimati(_ caratteri: Int) -> Int { Int(Double(caratteri) / 3.5) + 1 }
}

struct Budget: Codable, Equatable {
    var euroMese: Double = 5
    var mese = Budget.meseCorrente()
    var spesa = 0.0
    var chiamate = 0
    var perFunzione: [String: Double] = [:]

    static func meseCorrente() -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
    static let chiave = "budgetClaude"
    static func carica() -> Budget {
        guard let d = UserDefaults.standard.data(forKey: chiave),
              var b = try? JSONDecoder().decode(Budget.self, from: d) else { return Budget() }
        if b.mese != meseCorrente() { b.mese = meseCorrente(); b.spesa = 0; b.chiamate = 0; b.perFunzione = [:] }
        return b
    }
    func salva() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.chiave) }
    var residuo: Double { max(0, euroMese - spesa) }
}

enum ErroreClaude: LocalizedError {
    case chiaveMancante
    case budgetEsaurito(Double)
    case budgetInsufficiente(stima: Double, residuo: Double)
    case risposta(Int, String)

    var errorDescription: String? {
        switch self {
        case .chiaveMancante: return "Manca la chiave Claude: Impostazioni › Intelligenza artificiale."
        case .budgetEsaurito(let b): return String(format: "Budget del mese esaurito (%.2f €). Si rinnova il primo del mese o puoi alzarlo nelle Impostazioni.", b)
        case .budgetInsufficiente(let s, let r): return String(format: "Servono circa %.2f €, ne restano %.2f questo mese.", s, r)
        case .risposta(let c, let m): return "Claude ha risposto con un errore (\(c)): \(m)"
        }
    }
}

/// Unico punto dell'app che chiama Claude. Controlla il budget prima e registra il costo reale dopo.
actor ClienteClaude {
    static let condiviso = ClienteClaude()

    struct Risposta { var testo: String; var costo: Double; var input: Int; var output: Int }

    static var chiavePresente: Bool { !(Portachiavi.leggi("anthropic") ?? "").isEmpty }

    func invia(sistema: String, utente: String, modello: ModelloClaude, maxToken: Int = 4000,
               funzione: String) async throws -> Risposta {
        guard let chiave = Portachiavi.leggi("anthropic"), !chiave.isEmpty else { throw ErroreClaude.chiaveMancante }
        var b = Budget.carica()
        guard b.spesa < b.euroMese else { throw ErroreClaude.budgetEsaurito(b.euroMese) }
        let stima = modello.costo(input: ModelloClaude.tokenStimati(sistema.count + utente.count), output: maxToken / 3)
        guard stima <= b.residuo + 0.005 else { throw ErroreClaude.budgetInsufficiente(stima: stima, residuo: b.residuo) }

        let corpo: [String: Any] = ["model": modello.rawValue, "max_tokens": maxToken, "system": sistema,
                                    "messages": [["role": "user", "content": utente]]]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(chiave, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: corpo)
        req.timeoutInterval = 180
        let (dati, r) = try await URLSession.shared.data(for: req)
        let codice = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard let j = try? JSONSerialization.jsonObject(with: dati) as? [String: Any] else {
            throw ErroreClaude.risposta(codice, "risposta non leggibile")
        }
        guard codice == 200 else {
            let msg = ((j["error"] as? [String: Any])?["message"] as? String) ?? "errore"
            throw ErroreClaude.risposta(codice, msg)
        }
        let u = j["usage"] as? [String: Any] ?? [:]
        let ti = u["input_tokens"] as? Int ?? 0, to = u["output_tokens"] as? Int ?? 0
        let costo = modello.costo(input: ti, output: to)
        b = Budget.carica()
        b.spesa += costo; b.chiamate += 1; b.perFunzione[funzione, default: 0] += costo
        b.salva()
        let testo = ((j["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return Risposta(testo: testo, costo: costo, input: ti, output: to)
    }

    /// Estrae il primo array/oggetto JSON da una risposta testuale.
    static func json<T: Decodable>(_ t: T.Type, da testo: String) -> T? {
        let aperture: [Character] = ["[", "{"]
        guard let i = testo.firstIndex(where: { aperture.contains($0) }) else { return nil }
        let chiusura: Character = testo[i] == "[" ? "]" : "}"
        guard let f = testo.lastIndex(of: chiusura), f > i else { return nil }
        return try? JSONDecoder().decode(t, from: Data(testo[i...f].utf8))
    }
}
