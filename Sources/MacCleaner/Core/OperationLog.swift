import Foundation
import os

/// Registro de lo que se ha borrado: cuando, que, cuanto y como.
///
/// Responde a «¿que borre el martes?», que el informe de la limpieza no puede
/// contestar porque se cierra. Es texto plano, una linea por ruta, separado
/// por tabuladores para que se lea en Consola y se pueda pasar por `cut`:
///
///     2026-10-02T08:30:12+02:00  TRASH  OK  1234567  /Users/x/...  Xcode DerivedData
///
/// Solo se escribe al limpiar. Analizar no deja rastro.
final class OperationLog: @unchecked Sendable {

    static let shared = OperationLog(
        url: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MacCleaner/operations.log"))

    enum Action: String {
        case trash = "TRASH"
        case delete = "DELETE"
        case tool = "TOOL"
    }

    enum Status: String {
        case ok = "OK"
        case partial = "PARTIAL"
        case failed = "FAILED"
        case skipped = "SKIPPED"
    }

    let url: URL
    /// Pasado este tamano, el registro se aparta a `.1` y se empieza otro.
    let limit: Int
    private let lock = OSAllocatedUnfairLock()

    init(url: URL, limit: Int = 5 * 1024 * 1024) {
        self.url = url
        self.limit = limit
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func begin(rows: Int, toTrash: Bool, now: Date = Date()) {
        write("\(stamp(now))\tBEGIN\t\t\t\trows=\(rows) trash=\(toTrash ? "yes" : "no")")
    }

    func end(freed: Int64, now: Date = Date()) {
        write("\(stamp(now))\tEND\t\t\(freed)\t\t")
    }

    func record(_ action: Action, _ status: Status, bytes: Int64, path: String,
                detail: String, now: Date = Date()) {
        // Un salto de linea en un nombre partiria el registro en dos.
        let clean = { (text: String) in
            text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        write([stamp(now), action.rawValue, status.rawValue, String(max(0, bytes)),
               clean(path), clean(detail)].joined(separator: "\t"))
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func write(_ line: String) {
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > limit {
                let old = url.appendingPathExtension("1")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: url, to: old)
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
