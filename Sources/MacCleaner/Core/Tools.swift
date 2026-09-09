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
    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 600) -> Result {
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
        // dejar la limpieza colgada para siempre.
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }
}
