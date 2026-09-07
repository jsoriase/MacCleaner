import Foundation

/// Utilidades de bajo nivel sobre el sistema de ficheros.
/// Se usa `glob(3)` para expandir patrones y `fts(3)` para recorrer arboles:
/// ambos son C puro, sin objetos intermedios, asi que el consumo de memoria
/// es constante aunque la carpeta tenga cientos de miles de ficheros.
enum FileSystem {

    // MARK: - Expansion de patrones

    /// Expande un patron tipo `~/Library/Caches/JetBrains/*` a rutas reales.
    /// Solo devuelve rutas que existen.
    static func expand(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        let flags = GLOB_TILDE | GLOB_NOSORT | GLOB_NOESCAPE
        guard glob(pattern, flags, nil, &g) == 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(Int(g.gl_matchc))
        for i in 0..<Int(g.gl_matchc) {
            if let raw = g.gl_pathv[i] {
                result.append(String(cString: raw))
            }
        }
        return result
    }

    // MARK: - Rutas intocables

    /// Carpetas que macOS protege con TCC. Con solo leerlas se dispara un dialogo
    /// de permisos que congela el hilo hasta que el usuario responde, asi que
    /// MacCleaner las ignora por completo: ni las mide ni las borra.
    private static let protectedNames: Set<String> = [
        "com.apple.AMPLibraryAgent", "com.apple.Music", "com.apple.iTunes",
        "com.apple.iTunesCloud", "com.apple.itunes.swinfo", "com.apple.AppleMediaServices",
        "com.apple.amsengagementd", "com.apple.mediaanalysisd", "com.apple.tv",
        "com.apple.podcasts", "com.apple.Photos", "com.apple.photolibraryd",
        "com.apple.photoanalysisd", "com.apple.AddressBook", "com.apple.iCal",
        "com.apple.CalendarAgent", "com.apple.reminders", "com.apple.Safari",
        "com.apple.homed", "com.apple.assistantd", "com.apple.AssistantServices",
        "com.apple.Siri", "com.apple.SiriNCService", "com.apple.parsecd",
        "com.apple.suggestions", "com.apple.knowledge-agent", "CloudKit",
    ]

    private static let protectedPrefixes: [String] = [
        NSHomeDirectory() + "/Library/Application Support/MobileSync",
        NSHomeDirectory() + "/Library/Application Support/AddressBook",
        NSHomeDirectory() + "/Library/Application Support/CallHistory",
        NSHomeDirectory() + "/Library/Calendars",
        NSHomeDirectory() + "/Library/Messages",
        NSHomeDirectory() + "/Pictures",
        NSHomeDirectory() + "/Music",
        NSHomeDirectory() + "/Movies",
        NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Desktop",
        NSHomeDirectory() + "/Downloads",
    ]

    static func isProtected(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if protectedNames.contains(name) { return true }
        // Tambien cubre subcarpetas: .../com.apple.Music/algo
        for component in (path as NSString).pathComponents where protectedNames.contains(component) {
            return true
        }
        return protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Medicion de tamano

    struct Usage: Sendable {
        var bytes: Int64 = 0
        var files: Int = 0
        /// `st_mtime` mas reciente de todo el arbol, en segundos desde 1970.
        /// 0 significa que no se ha medido nada.
        var newest: time_t = 0

        static func + (lhs: Usage, rhs: Usage) -> Usage {
            Usage(bytes: lhs.bytes + rhs.bytes,
                  files: lhs.files + rhs.files,
                  newest: max(lhs.newest, rhs.newest))
        }

        /// Ultima vez que algo escribio aqui dentro. Es escritura, no lectura:
        /// macOS monta con `noatime`, asi que el acceso no deja rastro. Para una
        /// cache sirve igual, porque la herramienta que la usa tambien la escribe.
        var modified: Date? {
            newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil
        }
    }

    /// Espacio realmente ocupado en disco (bloques asignados, igual que `du`).
    /// No cruza puntos de montaje y no sigue enlaces simbolicos.
    static func usage(of path: String, isCancelled: () -> Bool = { false }) -> Usage {
        var info = stat()
        guard lstat(path, &info) == 0 else { return Usage() }

        if (info.st_mode & S_IFMT) != S_IFDIR {
            return Usage(bytes: Int64(info.st_blocks) * 512,
                         files: 1,
                         newest: info.st_mtimespec.tv_sec)
        }

        var usage = Usage()
        let duplicated = strdup(path)
        defer { free(duplicated) }
        var argv: [UnsafeMutablePointer<CChar>?] = [duplicated, nil]

        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return usage
        }
        defer { fts_close(stream) }

        var seen = 0
        while let entry = fts_read(stream) {
            let kind = Int32(entry.pointee.fts_info)
            if let st = entry.pointee.fts_statp {
                if kind == FTS_D {
                    usage.bytes += Int64(st.pointee.st_blocks) * 512
                    usage.newest = max(usage.newest, st.pointee.st_mtimespec.tv_sec)
                } else if kind == FTS_F || kind == FTS_SL || kind == FTS_SLNONE || kind == FTS_DEFAULT {
                    usage.bytes += Int64(st.pointee.st_blocks) * 512
                    usage.files += 1
                    usage.newest = max(usage.newest, st.pointee.st_mtimespec.tv_sec)
                }
            }
            seen += 1
            if seen & 0x3FF == 0 && isCancelled() { break }
        }
        return usage
    }

    // MARK: - Volumen

    struct Volume: Sendable, Equatable {
        var free: Int64
        var total: Int64
    }

    /// Espacio del disco donde vive el home. Se pregunta por la capacidad
    /// "para uso importante": es la que macOS liberaria de verdad si hiciera
    /// falta, y coincide con la que ensena Finder.
    static func homeVolume() -> Volume? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { return nil }
        return Volume(free: free, total: Int64(total))
    }

    // MARK: - Borrado

    /// Hijos directos de un directorio (rutas absolutas), sin recursion.
    static func children(of path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.map { (path as NSString).appendingPathComponent($0) }
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Borra una ruta. `toTrash` la mueve a la Papelera en lugar de eliminarla.
    static func remove(_ path: String, toTrash: Bool) throws {
        let url = URL(fileURLWithPath: path)
        if toTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Formato

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func humanBytes(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : formatter.string(fromByteCount: bytes)
    }

    /// "hace 14 meses". Lo traduce Foundation, asi que sale en el idioma del
    /// usuario sin pasar por nuestro catalogo. El idioma se toma del que el
    /// bundle haya elegido, igual que `appLayoutDirection`, para que forzar
    /// `-AppleLanguages` cambie tambien las fechas.
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f
    }()

    static func humanAge(_ date: Date, relativeTo now: Date = Date()) -> String {
        ageFormatter.localizedString(for: date, relativeTo: now)
    }

    /// Fecha completa para el tooltip.
    static func humanDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Medio ano sin escribir nada. A partir de aqui la fila se marca en ambar:
    /// es la senal de "esto ya no lo usas", que es justo lo que hay que borrar.
    static let staleInterval: TimeInterval = 180 * 24 * 60 * 60

    static func isStale(_ date: Date, relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) > staleInterval
    }

    /// Acorta rutas largas para la UI: `/Users/x/Library/...` -> `~/Library/...`
    static func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
