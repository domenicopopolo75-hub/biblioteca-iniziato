import Foundation

/// Porta di `pipeline/biblioteca_pipeline/normalizza.py`: stessi risultati sugli stessi casi di test.
enum Normalizza {
    private static let legature: [String: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl",
        "\u{FB05}": "st", "\u{FB06}": "st", "\u{00AD}": "",
    ]

    static func testo(_ s: String) -> String {
        var t = s
        for (k, v) in legature { t = t.replacingOccurrences(of: k, with: v) }
        t = t.precomposedStringWithCanonicalMapping
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // parola-<a capo>minuscola → unita
        t = t.replacingOccurrences(of: #"(\w)[-\u2010\u2011]\n(?=[a-zà-öø-ÿ])"#, with: "$1",
                                   options: .regularExpression)
        let righe = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        t = righe.filter { !$0.isEmpty }.joined(separator: " ")
        t = t.replacingOccurrences(of: "[ \\t\u{00A0}\u{2009}\u{202F}]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func chiaveRipetizione(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func numeroStampato(_ s: String) -> String? {
        for riga in s.components(separatedBy: .newlines) {
            let r = riga.trimmingCharacters(in: .whitespaces)
            if !r.isEmpty, r.count <= 4, r.allSatisfy(\.isNumber) { return r }
        }
        return nil
    }

    /// "he"/"el" se più della metà delle lettere è ebraica/greca.
    static func scriptDominante(_ s: String) -> String? {
        var lettere = 0, ebr = 0, gre = 0
        for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
            lettere += 1
            switch u.value {
            case 0x0590...0x05FF: ebr += 1
            case 0x0370...0x03FF, 0x1F00...0x1FFF: gre += 1
            default: break
            }
        }
        guard lettere > 0 else { return nil }
        if ebr * 2 > lettere { return "he" }
        if gre * 2 > lettere { return "el" }
        return nil
    }

    /// Divide un paragrafo in frasi raggruppate fino a `massimo` caratteri: unità di sintesi vocale.
    /// La traduzione resta per paragrafo intero (qualità); la voce lavora per frasi (latenza).
    static func segmentiVoce(_ s: String, massimo: Int = 280) -> [String] {
        var frasi: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let f = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { frasi.append(f) }
        }
        if frasi.isEmpty { return s.isEmpty ? [] : [s] }
        var out: [String] = []
        var corrente = ""
        for f in frasi {
            if corrente.isEmpty { corrente = f }
            else if corrente.count + 1 + f.count <= massimo { corrente += " " + f }
            else { out.append(corrente); corrente = f }
        }
        if !corrente.isEmpty { out.append(corrente) }
        return out
    }
}
