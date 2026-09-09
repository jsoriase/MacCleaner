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

    /// Un identificador protegido cubre tambien los suyos: `com.apple.Safari`
    /// protege a `com.apple.Safari.SafeBrowsing`. Sin esto, una cache hermana
    /// se colaba en el cajon de sastre y acabaria borrandose sin nombre propio
    /// el dia que alguien le diera Acceso total al disco a la app.
    private static func isProtectedName(_ name: String) -> Bool {
        protectedNames.contains(name)
            || protectedNames.contains { name.hasPrefix($0 + ".") }
    }

    static func isProtected(_ path: String) -> Bool {
        // Tambien cubre subcarpetas: .../com.apple.Music/algo
        for component in (path as NSString).pathComponents where isProtectedName(component) {
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
        // Un fichero con varios nombres ocupa disco una vez, no una por nombre.
        // Solo se apuntan los inodos con mas de un enlace, que son un punado:
        // asi la memoria sigue plana aunque el arbol tenga medio millon de
        // ficheros. Es lo mismo que hace `du`, y sin ello un almacen de pnpm
        // —que es enlaces duros de principio a fin— se cuenta varias veces.
        var countedLinks = Set<UInt64>()
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
                    // `files` cuenta entradas, que es lo que se ve en el Finder;
                    // `bytes` cuenta disco, que es lo que se recupera.
                    usage.files += 1
                    usage.newest = max(usage.newest, st.pointee.st_mtimespec.tv_sec)
                    let repeated = st.pointee.st_nlink > 1
                        && !countedLinks.insert(UInt64(st.pointee.st_ino)).inserted
                    if !repeated {
                        usage.bytes += Int64(st.pointee.st_blocks) * 512
                    }
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

    // MARK: - Artefactos de proyecto

    /// Busca carpetas de artefactos por nombre dentro de las carpetas de codigo.
    ///
    /// A diferencia del resto del catalogo, aqui la ruta no se sabe de antemano:
    /// depende de donde tenga cada uno el codigo. Se recorre con `fts`, igual
    /// que al medir, pero sin bajar: en cuanto una carpeta hace match se anota
    /// y se poda. Eso es lo que hace el recorrido barato, porque nadie llega a
    /// entrar en un `node_modules`.
    ///
    /// `pruning` es la lista entera de artefactos y `collecting` la parte que
    /// recoge esta fila. Se podan todos aunque solo se recojan algunos: sin eso
    /// un `build` dentro de un `node_modules` acabaria contado dos veces.
    static func artifactFolders(collecting: [String],
                                pruning: [String],
                                under roots: [String],
                                maxDepth: Int = 8) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        for root in roots {
            let duplicated = strdup(root)
            defer { free(duplicated) }
            var argv: [UnsafeMutablePointer<CChar>?] = [duplicated, nil]

            guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
            else { continue }
            defer { fts_close(stream) }

            while let entry = fts_read(stream) {
                guard Int32(entry.pointee.fts_info) == FTS_D,
                      let raw = entry.pointee.fts_path
                else { continue }

                let level = Int(entry.pointee.fts_level)
                guard level > 0 else { continue }   // la raiz no es un artefacto

                let path = String(cString: raw)
                let name = (path as NSString).lastPathComponent

                if matchesArtifact(name, pruning) {
                    fts_set(stream, entry, FTS_SKIP)
                    if matchesArtifact(name, collecting), seen.insert(path).inserted {
                        found.append(path)
                    }
                    continue
                }
                // Ni .git ni ningun otro escondite: ahi no hay artefactos y el
                // recorrido se dispara. Los que empiezan por punto y si lo son
                // (.build, .venv) ya han salido por la rama de arriba.
                if name.hasPrefix(".") || level >= maxDepth {
                    fts_set(stream, entry, FTS_SKIP)
                }
            }
        }
        return found
    }

    /// Un asterisco final vale como prefijo: `cmake-build-*`. No hace falta mas.
    static func matchesArtifact(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*")
                ? name.hasPrefix(String(pattern.dropLast()))
                : name == pattern
        }
    }

    // MARK: - Simuladores

    /// Un simulador es una carpeta con su `device.plist` dentro. En `Devices/`
    /// vive tambien `device_set.plist`, que es el registro de todos ellos y no
    /// se borra: sin esta comprobacion sale como si fuera un dispositivo mas.
    static func isSimulatorDevice(_ path: String) -> Bool {
        isDirectory(path)
            && FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent("device.plist"))
    }

    /// Nombre legible de un simulador a partir de su carpeta.
    ///
    /// La carpeta se llama como el UDID, que no le dice nada a nadie. El nombre
    /// y el sistema estan en `device.plist`, al lado. Devuelve nil si el plist
    /// no esta: entonces la fila se queda con el UDID, que es mejor que mentir.
    static func simulatorName(of path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("device.plist")
        guard let device = NSDictionary(contentsOfFile: plist),
              let name = device["name"] as? String, !name.isEmpty
        else { return nil }

        guard let runtime = device["runtime"] as? String,
              let short = simulatorRuntimeName(runtime)
        else { return name }
        return "\(name) · \(short)"
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` -> `iOS 26.5`.
    static func simulatorRuntimeName(_ identifier: String) -> String? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) " + parts.dropFirst().joined(separator: ".")
    }

    /// Acorta rutas largas para la UI: `/Users/x/Library/...` -> `~/Library/...`
    static func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
