import Foundation

/// Carpetas de codigo que el usuario anade a mano, ademas de las de
/// `Catalog.codeRoots`. Sirven para los barridos de proyectos: el codigo que
/// vive en un disco externo no aparece en las carpetas predeterminadas, que
/// estan dentro del home.
///
/// Se guardan en UserDefaults como rutas ya resueltas, sin enlaces. Cada una
/// se vuelve a validar cada vez que se usa: un disco desmontado o una carpeta
/// borrada no aporta raiz, pero sigue guardada por si vuelve.
enum CodeRoots {

    static let defaultsKey = "code.roots"

    /// Por que una carpeta no se puede anadir. El nombre de cada caso es la
    /// clave de su texto en `Localizable.strings`: `coderoots.reject.<caso>`.
    enum Rejection: Equatable {
        /// No es una ruta absoluta limpia: relativa, con caracteres de control o con `..`.
        case invalid
        /// No existe, o no es una carpeta.
        case missing
        /// Demasiado amplia: `/`, `/Volumes`, `/Users` o el home entero, o alguno de sus antecesores.
        case tooBroad
        /// La raiz de un disco. Lo que se elige es una carpeta dentro del disco.
        case volumeRoot
        /// Carpeta del sistema, de otro usuario o de una copia de seguridad.
        case system
        /// Carpeta protegida: `~/Library` o los datos que macOS guarda aparte.
        case protected
        /// Ya esta en la lista, o es una de las predeterminadas.
        case duplicate

        var message: String { L("coderoots.reject.\(self)") }
    }

    /// Nombres de primer nivel dentro de un disco que no son carpetas de
    /// codigo: el sistema, las copias de seguridad y los metadatos del propio
    /// disco. `/Volumes/<disco>/<uno de estos>/...` se rechaza.
    private static let systemNames: Set<String> = [
        "System", "Library", "Applications", "Users", "usr", "bin", "sbin",
        "private", "etc", "var", "opt", "cores", "dev", ".Trashes",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", "Backups.backupdb",
    ]

    // MARK: - Almacenamiento

    /// Las guardadas tal cual, sin mirar si siguen disponibles. Para la hoja,
    /// que muestra tambien las que faltan, marcadas.
    static func stored(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// Las que se pueden usar ahora mismo. No borra nada de `defaults`: un
    /// disco desmontado que vuelve a montarse vuelve a contar.
    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        stored(defaults).filter { check($0) == nil }
    }

    /// Anade una carpeta. Guarda la ruta resuelta, para que el enlace no
    /// cambie despues lo que se ha aprobado.
    static func add(_ path: String, to defaults: UserDefaults = .standard) -> Rejection? {
        if let rejection = check(path) { return rejection }
        guard let resolved = canonicalPath(path) else { return .missing }
        let current = stored(defaults)
        guard !current.contains(resolved), !defaultRoots().contains(resolved) else {
            return .duplicate
        }
        defaults.set(current + [resolved], forKey: defaultsKey)
        return nil
    }

    static func remove(_ path: String, from defaults: UserDefaults = .standard) {
        defaults.set(stored(defaults).filter { $0 != path }, forKey: defaultsKey)
    }

    /// Las predeterminadas ya resueltas, para no aceptar una de ellas dos veces.
    private static func defaultRoots() -> [String] {
        Catalog.codeRoots.compactMap { canonicalPath(FileSystem.expandTilde($0)) }
    }

    // MARK: - Validacion

    /// La comprobacion completa de una carpeta escrita por el usuario.
    static func check(_ path: String) -> Rejection? {
        guard path.hasPrefix("/"), !hasControl(path),
              !(path as NSString).pathComponents.contains("..")
        else { return .invalid }
        guard let canonical = canonicalPath(path), FileSystem.isDirectory(canonical) else {
            return .missing
        }
        return check(canonical: canonical)
    }

    /// La parte pura sobre cadenas: `path` ya tiene todos sus enlaces
    /// resueltos. Sin disco, para poder probar `/Volumes` sin tener discos.
    ///
    /// Dentro del home se acepta cualquier carpeta salvo `~/Library` y lo
    /// protegido. Fuera, solo carpetas de un disco externo, y nunca la raiz de
    /// un disco ni una de sistema. `/Volumes/Macintosh HD` resuelve a `/`, asi
    /// que cae en la regla de `tooBroad`.
    static func check(canonical path: String, home: String = NSHomeDirectory()) -> Rejection? {
        if path == "/" || path == "/Volumes" || path == "/Users" || path == home
            || home.hasPrefix(path + "/") {
            return .tooBroad
        }

        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            if relative == "Library" || relative.hasPrefix("Library/") { return .protected }
            return FileSystem.isProtected(path) ? .protected : nil
        }

        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/").map(String.init)
            // Solo `/Volumes/<disco>`: la raiz del disco.
            if parts.count == 2 { return .volumeRoot }
            if systemNames.contains(parts[2]) { return .system }
            // Una copia de Time Machine o una imagen de disco, en cualquier nivel.
            let backup = parts.contains { name in
                name == "Backups.backupdb" || name.hasSuffix(".backupbundle")
                    || name.hasSuffix(".sparsebundle")
            }
            if backup { return .system }
            return FileSystem.isProtected(path) ? .protected : nil
        }

        // /System, /usr, /opt, /private/tmp, /Applications, otros homes...
        return .system
    }

    private static func hasControl(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// La ruta con todos sus enlaces resueltos, o nil si no existe.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
