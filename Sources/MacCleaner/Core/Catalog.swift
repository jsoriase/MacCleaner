import Foundation

enum Risk: String, CaseIterable {
    case safe       // se regenera solo, sin efectos secundarios
    case rebuild    // seguro, pero la proxima compilacion / arranque sera lenta
    case caution    // requiere volver a descargar o pierdes datos utiles

    /// Texto del distintivo de cada fila.
    var label: String { L("risk.\(rawValue).label") }

    /// Texto de los botones de seleccion rapida.
    var plural: String { L("risk.\(rawValue).plural") }

    /// Explicacion que sale al pasar el raton por el boton.
    var help: String { L("risk.\(rawValue).help") }
}

/// Como se borra la ruta que ha hecho match.
enum Scope: Equatable {
    case contents   // vacia la carpeta pero la conserva (evita romper permisos/TCC)
    case item       // borra la ruta entera
}

/// Como se parte una fila en subcarpetas medibles por separado.
enum Expansion {
    case none
    /// Los hijos de cada ruta. `~/.gradle/caches` -> una fila por version.
    case children
    /// Las propias rutas que ha expandido el patron. `~/Library/Caches/*` ->
    /// una fila por app. Se usa cuando el glob ya recorta por donde interesa.
    case paths
}

/// Rutas que no se recuperan borrando: hay que pedirselo a la herramienta que
/// las creo. Borrar la carpeta a mano deja su registro apuntando a algo que ya
/// no existe, o se lleva por delante datos que la herramienta no ha guardado.
enum Reclaim {
    /// `xcrun simctl delete <UDID>`.
    case simulator
    /// `docker system prune --force`, a secas: se lleva la cache de
    /// construccion —que es donde esta el bulto— y deja en paz las imagenes
    /// etiquetadas y los volumenes.
    case docker
}

/// Que pasa exactamente si borras esta fila.
///
/// El nivel de riesgo dice cuanto cuidado hay que tener; esto dice por que. Son
/// pocas y compartidas a proposito: escribir un texto suelto para cada una de
/// las 58 filas serian 2.494 cadenas que traducir y ninguna forma de comprobar
/// que dicen la verdad. Asi, en cambio, cada fila declara su consecuencia y hay
/// tests que exigen que cuadre con su riesgo.
enum Consequence: String {
    /// Se rehace sola sin que nadie lo note.
    case regenerates
    /// No se pierde nada, pero la proxima compilacion tarda mas.
    case slowerBuild
    /// Hay que volver a bajarlo de la red.
    case redownload
    /// Hay que volver a crearlo a mano, y su estado no vuelve.
    case recreate
    /// No hay copia en ningun otro sitio.
    case dataLoss
    /// Cierra sesiones abiertas.
    case signOut
    /// Borra otro programa, y el decide que desaparece.
    case toolDecides
    /// Cajon de sastre: aqui cae lo que nadie ha nombrado.
    case unknown

    var text: String { L("why.\(rawValue)") }
}

/// De donde sale el texto de cada subcarpeta.
enum Naming {
    /// El nombre de la carpeta. Sirve para versiones, proyectos y apps.
    case folder
    /// Un UDID no dice nada: el nombre se lee de `device.plist`.
    case simulator
    /// Diez carpetas llamadas `build` no se distinguen entre si: hace falta la
    /// ruta desde el home para saber de que proyecto es cada una.
    case project
}

struct Target: Identifiable {
    let id: String
    let group: Category
    let risk: Risk
    let scope: Scope
    let patterns: [String]
    /// Si es true, se descartan las rutas ya cubiertas por otros targets.
    var isCatchAll: Bool = false
    /// Si no es `.none`, la fila se despliega y cada subcarpeta se mide y se
    /// marca por separado. Util cuando el contenido esta partido por version,
    /// por proyecto o por app.
    var expansion: Expansion = .none

    /// Si no es nil, limpiar esta fila ejecuta la herramienta en lugar de `rm`,
    /// y lo liberado se mide volviendo a pesar la ruta: es lo unico honesto
    /// cuando quien decide cuanto espacio devuelve es un programa ajeno.
    var reclaim: Reclaim? = nil
    /// Como se titula cada subcarpeta de una fila desplegable.
    var naming: Naming = .folder
    /// Nombres de carpeta que recoge esta fila recorriendo el arbol. Cuando no
    /// esta vacio, `patterns` son las carpetas de codigo donde mirar, no lo que
    /// se borra: los artefactos no viven en una ruta fija, viven donde cada uno
    /// tenga el codigo.
    var artifacts: [String] = []
    /// Que pasa si la borras. Sale al pasar el raton por su distintivo de
    /// riesgo. El valor por defecto solo vale para las filas seguras: un test
    /// exige que las demas declaren la suya.
    var why: Consequence = .regenerates

    var isSweep: Bool { !artifacts.isEmpty }

    var expandable: Bool { expansion != .none }

    /// El texto visible se deriva del id, asi que no puede desincronizarse
    /// de las traducciones: `target.gradle.caches.name` y `.note`.
    var name: String { L("target.\(id).name") }
    var note: String { L("target.\(id).note") }
}

extension Target {
    /// Las rutas reales de esta fila, antes de descartar las protegidas.
    ///
    /// Casi todas salen de expandir el patron. Las de barrido no: ahi el patron
    /// dice donde mirar y las rutas salen de recorrer el arbol buscando por
    /// nombre.
    func resolvePaths() -> [String] {
        let expanded = patterns.flatMap { FileSystem.expand($0) }
        if reclaim == .simulator {
            return expanded.filter(FileSystem.isSimulatorDevice)
        }
        guard isSweep else { return expanded }
        return FileSystem.artifactFolders(collecting: artifacts,
                                          pruning: Catalog.projectArtifacts,
                                          under: expanded)
    }
}

enum Category: String, CaseIterable, Identifiable {
    case xcode, jvm, node, langs, ai, projects, tools, browsers, system

    var id: String { rawValue }
    var title: String { L("category.\(rawValue)") }

    var symbol: String {
        switch self {
        case .xcode:  return "hammer"
        case .jvm:    return "cup.and.saucer"
        case .node:   return "globe"
        case .langs:  return "chevron.left.forwardslash.chevron.right"
        case .ai:     return "brain"
        case .projects: return "folder"
        case .browsers: return "safari"
        case .tools:  return "shippingbox"
        case .system: return "gearshape"
        }
    }
}

enum Catalog {

    /// Donde se busca codigo. Solo dentro del home: la regla de que fuera de el
    /// no se toca nada vale tambien aqui, y es la que hace que este barrido
    /// pueda existir sin pedir permisos nuevos.
    static let codeRoots = ["~/Projects", "~/Code", "~/dev", "~/Developer",
                            "~/src", "~/GitHub", "~/Workspace", "~/repos", "~/Sites"]

    /// Los navegadores de la familia Chromium comparten estructura: una carpeta
    /// por perfil y, dentro, siempre las mismas subcarpetas. Lo unico que cambia
    /// es donde vive la raiz. El `*` final recorre los perfiles —`Default`,
    /// `Profile 1`…— y se queda solo con los que tengan la subcarpeta que busca.
    static let browserProfiles = [
        "~/Library/Application Support/Google/Chrome/*",
        "~/Library/Application Support/Google/Chrome Beta/*",
        "~/Library/Application Support/Google/Chrome Canary/*",
        "~/Library/Application Support/BraveSoftware/Brave-Browser/*",
        "~/Library/Application Support/Microsoft Edge/*",
        "~/Library/Application Support/Chromium/*",
        "~/Library/Application Support/Vivaldi/*",
    ]

    private static func inProfiles(_ names: [String]) -> [String] {
        browserProfiles.flatMap { root in names.map { root + "/" + $0 } }
    }

    /// Firefox y sus derivados parten el perfil en dos: los datos en
    /// `Application Support` y la cache en `Caches`, con el mismo nombre de
    /// perfil en los dos sitios. Ese nombre lleva un prefijo aleatorio
    /// (`8f3k2a9x.default-release`), asi que solo vale el comodin.
    static let geckoVendors = ["Firefox", "LibreWolf", "Waterfox", "zen"]

    private static func inGeckoProfiles(_ names: [String]) -> [String] {
        geckoVendors.flatMap { vendor in
            names.map { "~/Library/Application Support/\(vendor)/Profiles/*/" + $0 }
        }
    }

    /// Lo que reinstala un gestor de paquetes.
    static let dependencyFolders = ["node_modules", "Pods", ".venv", "venv", "vendor"]

    /// Lo que rehace un compilador.
    static let outputFolders = ["build", ".build", "target", ".next", ".turbo",
                                "DerivedData", "cmake-build-*", "__pycache__"]

    /// Las dos filas de barrido podan por la lista entera aunque cada una
    /// recoja su mitad.
    static let projectArtifacts = dependencyFolders + outputFolders

    static let targets: [Target] = [

        // MARK: Xcode e iOS

        Target(id: "xcode.deriveddata",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/DerivedData"],
               expansion: .children,
               why: .slowerBuild),

        Target(id: "xcode.devicesupport",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/iOS DeviceSupport"],
               expansion: .children),

        Target(id: "xcode.devicesupport.other",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/watchOS DeviceSupport",
                          "~/Library/Developer/Xcode/tvOS DeviceSupport",
                          "~/Library/Developer/Xcode/visionOS DeviceSupport"]),

        Target(id: "xcode.caches",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Caches/com.apple.dt.Xcode"]),

        Target(id: "xcode.doccache",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/DocumentationCache",
                          "~/Library/Developer/Shared/Documentation/DocSets"]),

        Target(id: "xcode.previews",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/UserData/Previews"]),

        Target(id: "xcode.devicelogs",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/iOS Device Logs",
                          "~/Library/Logs/CoreSimulator"]),

        Target(id: "sim.caches",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/CoreSimulator/Caches"]),

        // Sustituye a la antigua fila de solo cachés: el simulador entero es lo
        // que pesa, y la carpeta no se borra a mano porque CoreSimulator se
        // queda con un dispositivo fantasma en su registro.
        Target(id: "sim.devices",
               group: .xcode, risk: .caution, scope: .item,
               patterns: ["~/Library/Developer/CoreSimulator/Devices/*"],
               expansion: .paths,
               reclaim: .simulator,
               naming: .simulator,
               why: .toolDecides),

        Target(id: "xcode.archives",
               group: .xcode, risk: .caution, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/Archives"],
               expansion: .children,
               why: .dataLoss),

        Target(id: "swiftpm",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/org.swift.swiftpm",
                          "~/.swiftpm/cache"],
               why: .redownload),

        Target(id: "cocoapods",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/CocoaPods"],
               why: .redownload),

        Target(id: "carthage",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/org.carthage.CarthageKit"],
               why: .redownload),

        // MARK: Android, Gradle y JVM

        Target(id: "gradle.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.gradle/caches"],
               expansion: .children,
               why: .redownload),

        Target(id: "gradle.daemon",
               group: .jvm, risk: .safe, scope: .contents,
               patterns: ["~/.gradle/daemon", "~/.gradle/native", "~/.gradle/workers"]),

        Target(id: "gradle.wrapper",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/.gradle/wrapper/dists"],
               expansion: .children,
               why: .redownload),

        Target(id: "android.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.android/cache", "~/.android/build-cache",
                          "~/Library/Android/sdk/.temp", "~/Library/Android/sdk/temp"],
               why: .slowerBuild),

        // El equivalente de un simulador de iOS: disco, estado y snapshots de
        // cada emulador. Los `.ini` de al lado son el registro que los lista,
        // asi que salen como hijos y se van con ellos.
        Target(id: "android.avd",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/.android/avd"],
               expansion: .children,
               why: .recreate),

        Target(id: "android.systemimages",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/Library/Android/sdk/system-images/*"],
               expansion: .paths,
               why: .redownload),

        Target(id: "jetbrains.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/JetBrains/*",
                          "~/Library/Caches/Google/AndroidStudio*"],
               expansion: .paths,
               why: .slowerBuild),

        Target(id: "jetbrains.logs",
               group: .jvm, risk: .safe, scope: .contents,
               patterns: ["~/Library/Logs/JetBrains/*",
                          "~/Library/Logs/Google/AndroidStudio*"],
               expansion: .paths),

        Target(id: "maven",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/.m2/repository"],
               why: .redownload),

        Target(id: "kotlin",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.konan/cache", "~/.kotlin/daemon"],
               why: .slowerBuild),

        // MARK: Node y web

        Target(id: "npm",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/.npm/_cacache", "~/.npm/_logs"],
               why: .redownload),

        Target(id: "yarn",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/Yarn", "~/.cache/yarn", "~/.yarn/berry/cache"],
               why: .redownload),

        Target(id: "pnpm",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/pnpm/store", "~/.pnpm-store"],
               why: .redownload),

        Target(id: "bun.deno",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/.bun/install/cache", "~/Library/Caches/deno", "~/.cache/deno"],
               why: .redownload),

        Target(id: "electron",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"],
               why: .redownload),

        // Las apps de Electron guardan su cache donde guardan sus datos, no en
        // ~/Library/Caches, asi que el cajon de sastre nunca las ve.
        Target(id: "electron.appsupport",
               group: .node, risk: .safe, scope: .contents,
               patterns: ["~/Library/Application Support/*/Cache",
                          "~/Library/Application Support/*/Code Cache",
                          "~/Library/Application Support/*/GPUCache",
                          "~/Library/Application Support/*/Service Worker/CacheStorage",
                          "~/Library/Application Support/*/*/Cache",
                          "~/Library/Application Support/*/*/Code Cache",
                          "~/Library/Application Support/*/*/GPUCache"],
               expansion: .paths),

        Target(id: "browsers.headless",
               group: .node, risk: .caution, scope: .contents,
               patterns: ["~/Library/Caches/ms-playwright", "~/.cache/puppeteer"],
               why: .redownload),

        // MARK: Otros lenguajes

        Target(id: "go.build",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/go-build"],
               why: .slowerBuild),

        Target(id: "go.mod",
               group: .langs, risk: .caution, scope: .contents,
               patterns: ["~/go/pkg/mod/cache/download"],
               why: .redownload),

        Target(id: "rust",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts"],
               why: .redownload),

        Target(id: "python",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/pip", "~/.cache/pip",
                          "~/Library/Caches/uv", "~/.cache/uv",
                          "~/Library/Caches/pypoetry"],
               why: .redownload),

        Target(id: "ruby",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.bundle/cache", "~/.gem/specs"],
               why: .redownload),

        Target(id: "flutter",
               group: .langs, risk: .caution, scope: .contents,
               patterns: ["~/.pub-cache/hosted", "~/.dartServer"],
               why: .redownload),

        Target(id: "php",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.composer/cache", "~/.cache/composer"],
               why: .redownload),

        // MARK: Herramientas de IA

        Target(id: "ai.worktrees",
               group: .ai, risk: .caution, scope: .contents,
               patterns: ["~/.codex/worktrees"],
               expansion: .children,
               why: .dataLoss),

        // «Cuidado», no «Se regenera»: el rootfs.img de 10 GB no es disperso y
        // no queda copia local de la que rehacerlo —la carpeta `warm` con su
        // mismo hash esta vacia—, asi que volver a tenerlo pasa por la red. Y
        // el sessiondata.img de al lado es estado de las sesiones, no cache.
        Target(id: "ai.vmbundles",
               group: .ai, risk: .caution, scope: .contents,
               patterns: ["~/Library/Application Support/Claude/vm_bundles",
                          "~/Library/Application Support/Claude/claude-code-vm"],
               expansion: .children,
               why: .redownload),

        Target(id: "ai.models",
               group: .ai, risk: .caution, scope: .contents,
               patterns: ["~/.ollama/models", "~/.cache/huggingface/hub",
                          "~/.cache/lm-studio/models", "~/.lmstudio/models"],
               expansion: .children,
               why: .redownload),

        Target(id: "ai.caches",
               group: .ai, risk: .safe, scope: .contents,
               patterns: ["~/.codex/cache", "~/.claude/cache",
                          "~/.claude/shell-snapshots", "~/.cursor/cache",
                          "~/Library/Caches/com.anthropic.claudefordesktop",
                          "~/Library/Caches/ai.opencode.desktop"]),

        // MARK: Proyectos

        Target(id: "projects.deps",
               group: .projects, risk: .caution, scope: .item,
               patterns: codeRoots,
               expansion: .paths,
               naming: .project,
               artifacts: dependencyFolders,
               why: .redownload),

        Target(id: "projects.builds",
               group: .projects, risk: .rebuild, scope: .item,
               patterns: codeRoots,
               expansion: .paths,
               naming: .project,
               artifacts: outputFolders,
               why: .slowerBuild),

        // MARK: Navegadores

        Target(id: "browsers.cache",
               group: .browsers, risk: .safe, scope: .contents,
               patterns: ["~/Library/Caches/Google/Chrome",
                          "~/Library/Caches/BraveSoftware",
                          "~/Library/Caches/Microsoft Edge",
                          "~/Library/Caches/Chromium",
                          "~/Library/Caches/Vivaldi"]
                   // En Firefox la carpeta de Caches es cache de arriba abajo,
                   // asi que se reclama entera y no hay que perseguir cache2.
                   + geckoVendors.map { "~/Library/Caches/\($0)" }
                   + inProfiles(["Cache", "Code Cache", "GPUCache",
                                 "DawnWebGPUCache", "DawnGraphiteCache",
                                 "ShaderCache", "GrShaderCache"])
                   + inGeckoProfiles(["storage/temporary", "storage/to-be-removed"])),

        Target(id: "browsers.serviceworkers",
               group: .browsers, risk: .rebuild, scope: .contents,
               patterns: inProfiles(["Service Worker"]),
               why: .redownload),

        Target(id: "browsers.storage",
               group: .browsers, risk: .caution, scope: .contents,
               patterns: inProfiles(["Local Storage", "Session Storage", "IndexedDB"])
                   // En Firefox aqui dentro viven tambien los service workers,
                   // asi que no hace falta fila aparte para ellos.
                   + inGeckoProfiles(["storage/default"]),
               why: .signOut),

        // Historial y cookies pesan poco: son privacidad, no espacio. Estan
        // porque se pidieron, con el nivel que les corresponde.
        //
        // Firefox no entra en esta fila: guarda el historial y los marcadores
        // en el mismo `places.sqlite`, asi que borrarlo se llevaria por delante
        // los favoritos de alguien. No hay forma de separarlos desde fuera.
        Target(id: "browsers.history",
               group: .browsers, risk: .caution, scope: .item,
               patterns: inProfiles(["History", "History-journal", "History-wal",
                                     "Visited Links", "Top Sites"]),
               why: .dataLoss),

        Target(id: "browsers.cookies",
               group: .browsers, risk: .caution, scope: .item,
               patterns: inProfiles(["Cookies", "Cookies-journal", "Cookies-wal"])
                   + inGeckoProfiles(["cookies.sqlite", "cookies.sqlite-wal",
                                      "cookies.sqlite-shm"]),
               why: .signOut),

        Target(id: "browsers.updater",
               group: .browsers, risk: .safe, scope: .contents,
               patterns: ["~/Library/Application Support/Google/GoogleUpdater",
                          "~/Library/Caches/com.google.Keystone",
                          "~/Library/Application Support/BraveSoftware/Updater",
                          "~/Library/Caches/BraveSoftware.Updater",
                          "~/Library/Caches/Mozilla",
                          "~/Library/Application Support/Mozilla/updates"]),

        // MARK: Gestores de paquetes

        Target(id: "homebrew",
               group: .tools, risk: .safe, scope: .contents,
               patterns: ["~/Library/Caches/Homebrew"]),

        Target(id: "docker.logs",
               group: .tools, risk: .safe, scope: .contents,
               patterns: ["~/Library/Containers/com.docker.docker/Data/log"]),

        // El fichero es disperso: `Docker.raw` declara cientos de GB y ocupa los
        // que ocupa. Se mide con st_blocks, como `du`, asi que sale el real.
        Target(id: "docker.disk",
               group: .tools, risk: .caution, scope: .item,
               patterns: ["~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw",
                          "~/Library/Containers/com.docker.docker/Data/vms/*/Docker.raw"],
               reclaim: .docker,
               why: .toolDecides),

        // MARK: Sistema y apps

        Target(id: "user.logs",
               group: .system, risk: .safe, scope: .contents,
               patterns: ["~/Library/Logs/DiagnosticReports", "~/Library/Logs/*.log"]),

        Target(id: "trash",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/.Trash"],
               why: .dataLoss),

        Target(id: "savedstate",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/Library/Saved Application State"],
               why: .dataLoss),

        // Aqui vivio una fila para las copias de iOS, en
        // ~/Library/Application Support/MobileSync/Backup. No puede existir:
        // MobileSync esta en `FileSystem.protectedPrefixes`, asi que
        // `isProtected` la descarta antes de medirla y la fila salia siempre
        // vacia por mucho respaldo que hubiera. Leer esa carpeta exige Acceso
        // total al disco, que es justo lo que esta app no pide. Si algun dia lo
        // pidiera, habria que quitar tambien el prefijo.

        // Las apps en sandbox no escriben en ~/Library/Caches: cada una tiene su
        // propia copia dentro del contenedor.
        Target(id: "containers.caches",
               group: .system, risk: .safe, scope: .contents,
               patterns: ["~/Library/Containers/*/Data/Library/Caches",
                          "~/Library/Group Containers/*/Library/Caches"],
               isCatchAll: true,
               expansion: .paths),

        Target(id: "installers.old",
               group: .system, risk: .safe, scope: .contents,
               patterns: ["~/Library/Application Support/com.docker.install",
                          "~/Library/Caches/com.apple.SoftwareUpdate",
                          "~/Library/Caches/com.apple.appstore"]),

        Target(id: "caches.other",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/Library/Caches/*"],
               isCatchAll: true,
               expansion: .paths,
               why: .unknown),
    ]

    static func targets(in group: Category) -> [Target] {
        targets.filter { $0.group == group }
    }
}
