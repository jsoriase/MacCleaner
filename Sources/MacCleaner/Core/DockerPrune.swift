import Foundation

/// Lo que `docker system prune` puede devolver de verdad.
///
/// La fila apunta a `Docker.raw`, el disco de la maquina virtual, pero lo que
/// ocupa ese fichero no es lo que se ofrece: dentro viven tambien las imagenes
/// etiquetadas, los volumenes y la cache que comparte capas con ellas, y el
/// prune los deja en paz a proposito. Ensenar el fichero entero prometia
/// 5,6 GB y luego se liberaban 8 KB. Que se lleva el prune solo lo sabe
/// Docker, asi que se le pregunta.
enum DockerPrune {

    /// Bytes que liberaria ahora mismo `docker system prune --force`. nil si
    /// no se puede preguntar: sin `docker`, o con Docker cerrado, que es justo
    /// cuando tampoco se podria lanzar el prune.
    static func prunable() -> Int64? {
        guard let docker = Tools.locate("docker") else { return nil }
        let usage = Tools.run(docker, ["system", "df", "--verbose", "--format", "json"], timeout: 60)
        guard usage.ok else { return nil }
        let dangling = Tools.run(docker, ["image", "ls", "--all", "--quiet", "--no-trunc",
                                          "--filter", "dangling=true"], timeout: 60)
        guard dangling.ok else { return nil }
        // stderr va por la misma tuberia: un aviso delante del JSON no puede
        // romper la cuenta.
        guard let start = usage.output.firstIndex(of: "{"),
              let end = usage.output.lastIndex(of: "}") else { return nil }
        let ids = dangling.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("sha256:") }
        return prunable(usage: Data(usage.output[start...end].utf8), dangling: Set(ids))
    }

    /// Estados en los que el prune se lleva un contenedor. Uno en pausa o
    /// reiniciandose cuenta como arrancado, y ese no lo toca.
    private static let stopped: Set<String> = ["created", "exited", "dead"]

    /// Cache que sin `--all` se queda: la del frontend de Dockerfile y la
    /// interna de BuildKit.
    private static let keptCache: Set<String> = ["internal", "frontend"]

    /// La cuenta, separada de `docker` para poder probarla con JSON fijo.
    ///
    /// `usage` es la salida de `docker system df --verbose --format json`;
    /// `dangling`, los identificadores de las imagenes colgantes. Lo que se
    /// suma es lo que deja de existir al borrarlo:
    ///
    /// - De los contenedores parados, su capa escribible.
    /// - De las imagenes colgantes sin contenedor, lo que no comparten con
    ///   ninguna otra.
    /// - De la cache de construccion, la que nadie usa y no comparte capas
    ///   con una imagen. Con el almacen de containerd casi toda la cache es
    ///   compartida: borrarla no devuelve nada mientras la imagen siga ahi.
    ///
    /// Ante la duda, se cuenta de menos: prometer de mas es justo lo que
    /// habia que dejar de hacer.
    static func prunable(usage: Data, dangling: Set<String>) -> Int64? {
        guard let root = try? JSONSerialization.jsonObject(with: usage) as? [String: Any]
        else { return nil }

        func rows(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }

        let containers = rows("Containers")
            .filter { stopped.contains(($0["State"] as? String ?? "").lowercased()) }
            .map { bytes($0["Size"]) }
        // Una colgante con contenedor es la version vieja que sigue corriendo
        // tras reconstruir la etiqueta, y esa no se la lleva. Si el contenedor
        // esta parado si, pero no se cuenta: mejor prometer de menos.
        let images = rows("Images")
            .filter { dangling.contains($0["ID"] as? String ?? "") }
            .filter { ($0["Containers"] as? String).flatMap { Int($0) } == 0 }
            .map { bytes($0["UniqueSize"]) }
        let cache = rows("BuildCache")
            .filter { flag($0["InUse"]) == false && flag($0["Shared"]) == false }
            .filter { !keptCache.contains($0["CacheType"] as? String ?? "") }
            .map { bytes($0["Size"]) }

        return (containers + images + cache).reduce(0, +)
    }

    /// `docker` escribe los booleanos como texto en este listado.
    private static func flag(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        switch value as? String {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func bytes(_ value: Any?) -> Int64 {
        guard let text = value as? String else { return 0 }
        return bytes(text) ?? 0
    }

    /// Un tamano tal como lo escribe `docker`: `81.11MB`, `638.3kB`, `0B`.
    ///
    /// Son unidades decimales, no binarias, y el numero sale de un `%g`, asi
    /// que tambien puede venir en notacion cientifica: una imagen que comparte
    /// mas de lo que ocupa sale como `-4.91e+07B`. Lo negativo cuenta como
    /// nada. Un contenedor puede anadir `(virtual 611MB)` detras: vale el
    /// primero.
    static func bytes(_ text: String) -> Int64? {
        guard let token = text.split(separator: " ").first else { return nil }
        let units: [(String, Double)] = [
            ("kB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("PB", 1e15), ("EB", 1e18),
            ("B", 1),
        ]
        for (suffix, scale) in units where token.hasSuffix(suffix) {
            guard let number = Double(token.dropLast(suffix.count)), number.isFinite
            else { return nil }
            return Int64(max(0, number * scale).rounded())
        }
        return nil
    }

    // MARK: - Esperar al disco

    /// Cuanto ha encogido el disco de la maquina virtual.
    ///
    /// Que Docker borre algo no devuelve el hueco al Mac en el acto: la
    /// maquina virtual avisa de los bloques libres por tandas, y `Docker.raw`
    /// tarda unos segundos en adelgazar. En una prueba, 200 MB borrados no se
    /// notaron hasta el septimo. Medirlo al momento daba unos pocos KB
    /// liberados cuando Docker si habia borrado.
    ///
    /// Se vuelve a mirar cada `pause` hasta que llega lo esperado, hasta que
    /// deja de moverse despues de haber devuelto al menos la mitad, o hasta
    /// agotar `rounds`. Lo de la mitad no es capricho: nada mas acabar el
    /// prune el fichero ya baja unos KB de metadatos, y tomar eso por la
    /// tanda buena cortaba la espera a los tres segundos con 8 KB contados.
    static func shrink(from before: Int64, expecting expected: Int64,
                       rounds: Int = 20,
                       isCancelled: () -> Bool = { false },
                       pause: () -> Void = { Thread.sleep(forTimeInterval: 1) },
                       measure: () -> Int64) -> Int64 {
        var best = max(0, before - measure())
        // Lo que se pierde por el camino —metadatos, bloques a medias— no
        // justifica esperar 20 segundos mas.
        let enough = expected - expected / 10
        var still = 0
        var round = 0
        while expected > 0, best < enough, round < rounds, still < 3, !isCancelled() {
            pause()
            round += 1
            let now = max(0, before - measure())
            if now > best {
                best = now
                still = 0
            } else if best >= expected / 2 {
                still += 1
            }
        }
        return best
    }
}
