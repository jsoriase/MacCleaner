import Foundation
import os

/// Los runtimes de simulador: la imagen de iOS, watchOS… que usan los
/// simuladores. Cada una son 7-10 GB y no vive en el home: la monta el sistema
/// desde `/Library/Developer/CoreSimulator` o desde los assets de software.
/// No se borran a mano —ni podriamos sin ser administrador—: se le pide a
/// `simctl runtime delete`, que es lo mismo que hace Xcode desde Ajustes.
///
/// Solo se ofrecen los huerfanos: listos, borrables, sin ningun simulador que
/// los use y sin otra imagen que sirva el mismo runtime. Uno con simuladores
/// es justo el que necesitas para ejecutarlos.
enum SimRuntimes {

    struct Runtime: Sendable, Equatable {
        /// UUID de la imagen: lo que pide `simctl runtime delete`.
        var identifier: String
        /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5`: lo que apunta cada
        /// simulador en su `device.plist`.
        var runtime: String
        /// Donde esta montado. Es la ruta que se ensena y se revela en el Finder.
        var bundlePath: String
        var title: String
        var bytes: Int64
        var lastUsed: Date?
    }

    /// El ultimo listado, para no lanzar `simctl` dos veces en un analisis:
    /// una para saber que rutas hay y otra para medirlas.
    private static let last = OSAllocatedUnfairLock<[Runtime]>(initialState: [])

    /// Lista los huerfanos y se los guarda para `cached`.
    static func scan() -> [Runtime] {
        let found = orphans() ?? []
        last.withLock { $0 = found }
        return found
    }

    static func cached(at path: String) -> Runtime? {
        last.withLock { list in list.first { $0.bundlePath == path } }
    }

    /// Los huerfanos de ahora mismo. nil si no se puede preguntar: sin Xcode,
    /// o si `simctl` no contesta.
    static func orphans() -> [Runtime]? {
        guard let images = simctl(["runtime", "list", "-j"]),
              let devices = simctl(["list", "devices", "-j"]) else { return nil }
        return orphans(images: images, devices: devices)
    }

    /// La decision, separada de `simctl` para poder probarla con JSON fijo.
    static func orphans(images: Data, devices: Data) -> [Runtime]? {
        guard let imageTable = try? JSONSerialization.jsonObject(with: images) as? [String: Any],
              let deviceRoot = try? JSONSerialization.jsonObject(with: devices) as? [String: Any],
              let deviceTable = deviceRoot["devices"] as? [String: Any]
        else { return nil }

        // Sin la lista de simuladores no hay prueba de que no se use: la
        // ausencia de pruebas no es prueba de ausencia.
        var used = Set<String>()
        for (runtime, list) in deviceTable {
            if let list = list as? [Any], !list.isEmpty { used.insert(runtime) }
        }

        let all: [Runtime] = imageTable.values.compactMap { value in
            guard let image = value as? [String: Any],
                  let identifier = image["identifier"] as? String,
                  let runtime = image["runtimeIdentifier"] as? String,
                  let bundle = image["runtimeBundlePath"] as? String,
                  (image["state"] as? String) == "Ready",
                  (image["deletable"] as? Bool) == true,
                  bundle.hasPrefix("/")
            else { return nil }

            let version = image["version"] as? String ?? ""
            let build = image["build"] as? String ?? ""
            let platform = FileSystem.simulatorRuntimeName(runtime)?
                .split(separator: " ").first.map(String.init) ?? "Simulator"
            var title = platform
            if !version.isEmpty { title += " " + version }
            if !build.isEmpty { title += " (\(build))" }

            let bytes = (image["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let lastUsed = (image["lastUsedAt"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return Runtime(identifier: identifier, runtime: runtime, bundlePath: bundle,
                           title: title, bytes: bytes, lastUsed: lastUsed)
        }

        // Dos imagenes para el mismo runtime: no se sabe cual de las dos usan
        // los simuladores que vengan, asi que no se ofrece ninguna.
        var served: [String: Int] = [:]
        for image in all { served[image.runtime, default: 0] += 1 }

        return all
            .filter { served[$0.runtime] == 1 && !used.contains($0.runtime) }
            .sorted { $0.bytes > $1.bytes }
    }

    static func delete(_ identifier: String) -> Tools.Result {
        Tools.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier], timeout: 600)
    }

    /// `simctl` solo existe con Xcode. Con las herramientas de linea de
    /// comandos sueltas, `xcrun` no lo encuentra; sin nada, ni se intenta.
    private static func simctl(_ arguments: [String]) -> Data? {
        guard Tools.developerDirectory != nil else { return nil }
        let result = Tools.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 60)
        guard result.ok else { return nil }
        // stderr va por la misma tuberia: un aviso de simctl delante del JSON
        // no puede romper el listado.
        guard let start = result.output.firstIndex(of: "{"),
              let end = result.output.lastIndex(of: "}") else { return nil }
        return Data(result.output[start...end].utf8)
    }
}
