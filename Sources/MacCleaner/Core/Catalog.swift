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

    var expandable: Bool { expansion != .none }

    /// El texto visible se deriva del id, asi que no puede desincronizarse
    /// de las traducciones: `target.gradle.caches.name` y `.note`.
    var name: String { L("target.\(id).name") }
    var note: String { L("target.\(id).note") }
}

enum Category: String, CaseIterable, Identifiable {
    case xcode, jvm, node, langs, tools, system

    var id: String { rawValue }
    var title: String { L("category.\(rawValue)") }

    var symbol: String {
        switch self {
        case .xcode:  return "hammer"
        case .jvm:    return "cup.and.saucer"
        case .node:   return "globe"
        case .langs:  return "chevron.left.forwardslash.chevron.right"
        case .tools:  return "shippingbox"
        case .system: return "gearshape"
        }
    }
}

enum Catalog {

    static let targets: [Target] = [

        // MARK: Xcode e iOS

        Target(id: "xcode.deriveddata",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/DerivedData"],
               expansion: .children),

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

        Target(id: "sim.devicedata",
               group: .xcode, risk: .safe, scope: .contents,
               patterns: ["~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches",
                          "~/Library/Developer/CoreSimulator/Devices/*/data/tmp"]),

        Target(id: "xcode.archives",
               group: .xcode, risk: .caution, scope: .contents,
               patterns: ["~/Library/Developer/Xcode/Archives"],
               expansion: .children),

        Target(id: "swiftpm",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/org.swift.swiftpm",
                          "~/.swiftpm/cache"]),

        Target(id: "cocoapods",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/CocoaPods"]),

        Target(id: "carthage",
               group: .xcode, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/org.carthage.CarthageKit"]),

        // MARK: Android, Gradle y JVM

        Target(id: "gradle.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.gradle/caches"],
               expansion: .children),

        Target(id: "gradle.daemon",
               group: .jvm, risk: .safe, scope: .contents,
               patterns: ["~/.gradle/daemon", "~/.gradle/native", "~/.gradle/workers"]),

        Target(id: "gradle.wrapper",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/.gradle/wrapper/dists"],
               expansion: .children),

        Target(id: "android.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.android/cache", "~/.android/build-cache",
                          "~/Library/Android/sdk/.temp", "~/Library/Android/sdk/temp"]),

        Target(id: "jetbrains.caches",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/JetBrains/*",
                          "~/Library/Caches/Google/AndroidStudio*"],
               expansion: .paths),

        Target(id: "jetbrains.logs",
               group: .jvm, risk: .safe, scope: .contents,
               patterns: ["~/Library/Logs/JetBrains/*",
                          "~/Library/Logs/Google/AndroidStudio*"],
               expansion: .paths),

        Target(id: "maven",
               group: .jvm, risk: .caution, scope: .contents,
               patterns: ["~/.m2/repository"]),

        Target(id: "kotlin",
               group: .jvm, risk: .rebuild, scope: .contents,
               patterns: ["~/.konan/cache", "~/.kotlin/daemon"]),

        // MARK: Node y web

        Target(id: "npm",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/.npm/_cacache", "~/.npm/_logs"]),

        Target(id: "yarn",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/Yarn", "~/.cache/yarn", "~/.yarn/berry/cache"]),

        Target(id: "pnpm",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/pnpm/store", "~/.pnpm-store"]),

        Target(id: "bun.deno",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/.bun/install/cache", "~/Library/Caches/deno", "~/.cache/deno"]),

        Target(id: "electron",
               group: .node, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"]),

        Target(id: "browsers.headless",
               group: .node, risk: .caution, scope: .contents,
               patterns: ["~/Library/Caches/ms-playwright", "~/.cache/puppeteer"]),

        // MARK: Otros lenguajes

        Target(id: "go.build",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/go-build"]),

        Target(id: "go.mod",
               group: .langs, risk: .caution, scope: .contents,
               patterns: ["~/go/pkg/mod/cache/download"]),

        Target(id: "rust",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts"]),

        Target(id: "python",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/Library/Caches/pip", "~/.cache/pip",
                          "~/Library/Caches/uv", "~/.cache/uv",
                          "~/Library/Caches/pypoetry"]),

        Target(id: "ruby",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.bundle/cache", "~/.gem/specs"]),

        Target(id: "flutter",
               group: .langs, risk: .caution, scope: .contents,
               patterns: ["~/.pub-cache/hosted", "~/.dartServer"]),

        Target(id: "php",
               group: .langs, risk: .rebuild, scope: .contents,
               patterns: ["~/.composer/cache", "~/.cache/composer"]),

        // MARK: Gestores de paquetes

        Target(id: "homebrew",
               group: .tools, risk: .safe, scope: .contents,
               patterns: ["~/Library/Caches/Homebrew"]),

        Target(id: "docker.logs",
               group: .tools, risk: .safe, scope: .contents,
               patterns: ["~/Library/Containers/com.docker.docker/Data/log"]),

        // MARK: Sistema y apps

        Target(id: "user.logs",
               group: .system, risk: .safe, scope: .contents,
               patterns: ["~/Library/Logs/DiagnosticReports", "~/Library/Logs/*.log"]),

        Target(id: "trash",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/.Trash"]),

        Target(id: "savedstate",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/Library/Saved Application State"]),

        Target(id: "ios.backups",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/Library/Application Support/MobileSync/Backup"]),

        Target(id: "caches.other",
               group: .system, risk: .caution, scope: .contents,
               patterns: ["~/Library/Caches/*"],
               isCatchAll: true,
               expansion: .paths),
    ]

    static func targets(in group: Category) -> [Target] {
        targets.filter { $0.group == group }
    }
}
