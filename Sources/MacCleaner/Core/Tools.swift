import Foundation

/// Ejecutar programas ajenos.
///
/// Hace falta para las rutas que no se recuperan borrando. La carpeta de un
/// simulador no se borra con `rm`: CoreSimulator se queda con un dispositivo
/// fantasma en su registro. El disco de la maquina virtual de Docker tampoco:
/// dentro viven las imagenes y los volumenes, y Docker es el unico que sabe
/// cuales sobran. En los dos casos la herramienta es la que manda, y nosotros
/// solo medimos antes y despues.
enum Tools {

    struct Result: Sendable {
        var status: Int32
        var output: String

        var ok: Bool { status == 0 }

        /// Primera linea util de lo que haya escrito la herramienta. Es lo que
        /// acaba en el informe de errores, asi que interesa corta.
        var firstLine: String {
            output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
        }
    }

    /// Una app de GUI no hereda el PATH del shell: arranca con `/usr/bin:/bin`
    /// y poco mas, asi que `docker` hay que buscarlo donde de verdad esta.
    private static let searchPaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        NSHomeDirectory() + "/.docker/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ]

    static func locate(_ name: String) -> String? {
        searchPaths
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Lanza el programa y espera a que termine. `stdout` y `stderr` van a la
    /// misma tuberia y se leen hasta el final antes de esperar: al reves, un
    /// programa hablador llena el buffer y se queda bloqueado para siempre.
    ///
    /// `isCancelled` se consulta desde otro hilo mientras el programa corre, y
    /// en cuanto dice que si se le termina.
    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 600,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Sin terminal interactiva: que ninguna herramienta se pare a preguntar.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }

        // Un `docker system prune` puede tardar minutos; lo que no puede es
        // dejar la limpieza colgada para siempre, ni seguir cuando el usuario
        // ha pulsado Detener.
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        watchdog.setEventHandler { [weak process] in
            guard let process, process.isRunning else { return }
            if isCancelled() || Date() >= deadline { process.terminate() }
        }
        watchdog.resume()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Git

    /// Un `git` de verdad, o nil.
    ///
    /// `/usr/bin/git` es solo un envoltorio: sin las herramientas de linea de
    /// comandos instaladas, ejecutarlo abre el dialogo para instalarlas en
    /// mitad del analisis. `xcode-select -p` no abre nada y dice donde estan,
    /// si estan.
    static let git: String? = {
        let developer = run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        if developer.ok {
            let candidate = developer.firstLine + "/usr/bin/git"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Las carpetas de `paths` que guardan algo versionado en git.
    ///
    /// Que una carpeta se llame `build` no la convierte en salida de un
    /// compilador: hay repos que guardan ahi codigo propio, como el `build/`
    /// de VS Code. Lo que esta en git lo ha escrito alguien, asi que no es un
    /// artefacto. Se pregunta una vez por repositorio, con todas sus
    /// candidatas juntas.
    ///
    /// El repositorio se busca hacia arriba sin salir de `roots`: un home que
    /// sea un repo de dotfiles no tiene nada que decir sobre los proyectos.
    /// Sin git, o si git no sabe contestar, no se descarta nada y quedan los
    /// marcadores de `Catalog.artifactMarkers` como unica comprobacion.
    static func versioned(_ paths: [String], within roots: [String]) -> Set<String> {
        guard let git, !paths.isEmpty else { return [] }

        var result = Set<String>()
        var byRepo: [String: [String]] = [:]
        for path in paths {
            // Un repo entero con nombre de artefacto: todo lo de dentro es suyo.
            if FileManager.default.fileExists(atPath: path + "/.git") {
                result.insert(path)
            } else if let repo = repository(containing: path, within: roots) {
                byRepo[repo, default: []].append(path)
            }
        }

        for (repo, candidates) in byRepo {
            let relative = candidates.map { String($0.dropFirst(repo.count + 1)) }
            let listing = run(git, ["--literal-pathspecs", "-C", repo, "ls-files", "-z", "--"] + relative,
                              timeout: 30)
            guard listing.ok else { continue }
            let tracked = listing.output.split(separator: "\0").map(String.init)
            for (path, rel) in zip(candidates, relative)
            where tracked.contains(where: { $0 == rel || $0.hasPrefix(rel + "/") }) {
                result.insert(path)
            }
        }
        return result
    }

    /// La carpeta con `.git` mas cercana por encima de `path`, sin pasar de la
    /// raiz que la contiene. `.git` puede ser carpeta o fichero: en un
    /// submodulo o un worktree es un fichero que apunta al repo de verdad.
    private static func repository(containing path: String, within roots: [String]) -> String? {
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count >= root.count {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
