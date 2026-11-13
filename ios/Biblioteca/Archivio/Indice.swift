import Foundation
import SQLite3

/// Indice di ricerca a testo pieno (SQLite FTS5) su tutti i libri: testo originale e traduzione italiana.
/// Ricerca gratuita e offline; è anche la base delle domande a Claude (si mandano solo i passi trovati).
final class Indice {
    struct Riscontro: Identifiable, Hashable {
        var id: String { "\(libro)#\(ordine)" }
        var libro: String
        var ordine: Int
        var testo: String
        var italiano: String?
        var estratto: String
        var punteggio: Double
    }

    private var db: OpaquePointer?
    private let coda = DispatchQueue(label: "indice.sqlite")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(percorso: URL) {
        coda.sync {
            sqlite3_open_v2(percorso.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            esegui("PRAGMA journal_mode=WAL")
            esegui("""
            CREATE VIRTUAL TABLE IF NOT EXISTS blocchi USING fts5(
              libro UNINDEXED, ordine UNINDEXED, testo, italiano,
              tokenize = 'unicode61 remove_diacritics 2')
            """)
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func esegui(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    var disponibile: Bool {
        coda.sync {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            return sqlite3_prepare_v2(db, "SELECT count(*) FROM blocchi", -1, &st, nil) == SQLITE_OK
        }
    }

    func contiene(libro: String) -> Bool {
        coda.sync {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            sqlite3_prepare_v2(db, "SELECT 1 FROM blocchi WHERE libro = ? LIMIT 1", -1, &st, nil)
            sqlite3_bind_text(st, 1, libro, -1, Self.transient)
            return sqlite3_step(st) == SQLITE_ROW
        }
    }

    /// (Re)indicizza un libro intero. Le traduzioni si aggiungono con `aggiornaItaliano`.
    func indicizza(libro: String, blocchi: [Blocco], italiano: [String: String] = [:]) {
        coda.sync {
            esegui("BEGIN")
            var del: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM blocchi WHERE libro = ?", -1, &del, nil)
            sqlite3_bind_text(del, 1, libro, -1, Self.transient)
            sqlite3_step(del); sqlite3_finalize(del)
            var ins: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO blocchi(libro, ordine, testo, italiano) VALUES (?,?,?,?)", -1, &ins, nil)
            for b in blocchi {
                sqlite3_reset(ins)
                sqlite3_bind_text(ins, 1, libro, -1, Self.transient)
                sqlite3_bind_int(ins, 2, Int32(b.order))
                sqlite3_bind_text(ins, 3, b.text, -1, Self.transient)
                if let it = italiano[b.id] { sqlite3_bind_text(ins, 4, it, -1, Self.transient) } else { sqlite3_bind_null(ins, 4) }
                sqlite3_step(ins)
            }
            sqlite3_finalize(ins)
            esegui("COMMIT")
        }
    }

    func aggiornaItaliano(libro: String, ordine: Int, testo: String) {
        coda.sync {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE blocchi SET italiano = ? WHERE libro = ? AND ordine = ?", -1, &st, nil)
            sqlite3_bind_text(st, 1, testo, -1, Self.transient)
            sqlite3_bind_text(st, 2, libro, -1, Self.transient)
            sqlite3_bind_int(st, 3, Int32(ordine))
            sqlite3_step(st); sqlite3_finalize(st)
        }
    }

    func rimuovi(libro: String) {
        coda.sync {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM blocchi WHERE libro = ?", -1, &st, nil)
            sqlite3_bind_text(st, 1, libro, -1, Self.transient)
            sqlite3_step(st); sqlite3_finalize(st)
        }
    }

    /// Trasforma parole libere in una query FTS5 sicura: termini tra virgolette, uniti con OR,
    /// con prefisso (`volont*`) per coprire plurali e declinazioni.
    static func query(_ parole: [String]) -> String {
        let termini = parole.flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        let unici = Array(NSOrderedSet(array: termini.map { $0.lowercased() })) as? [String] ?? []
        return unici.prefix(24).map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    func cerca(_ parole: [String], libri: [String]? = nil, limite: Int = 40) -> [Riscontro] {
        let q = Self.query(parole)
        guard !q.isEmpty else { return [] }
        return coda.sync {
            var sql = """
            SELECT libro, ordine, testo, italiano, snippet(blocchi, -1, '«', '»', '…', 24), bm25(blocchi)
            FROM blocchi WHERE blocchi MATCH ?
            """
            if let l = libri, !l.isEmpty { sql += " AND libro IN (" + l.map { _ in "?" }.joined(separator: ",") + ")" }
            sql += " ORDER BY bm25(blocchi) LIMIT \(limite)"
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(st, 1, q, -1, Self.transient)
            for (i, l) in (libri ?? []).enumerated() { sqlite3_bind_text(st, Int32(i + 2), l, -1, Self.transient) }
            var out: [Riscontro] = []
            while sqlite3_step(st) == SQLITE_ROW {
                func col(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
                out.append(Riscontro(libro: col(0) ?? "", ordine: Int(sqlite3_column_int(st, 1)), testo: col(2) ?? "",
                                     italiano: col(3), estratto: col(4) ?? "", punteggio: sqlite3_column_double(st, 5)))
            }
            return out
        }
    }
}
