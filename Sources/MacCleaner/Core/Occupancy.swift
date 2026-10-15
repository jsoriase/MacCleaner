import Foundation
import AppKit
import Darwin

/// Quien esta usando una ruta ahora mismo.
///
/// Borrar la cache de un programa mientras corre no es como borrarla con el
/// cerrado: Xcode con DerivedData a medio escribir, un daemon de Gradle que
/// ejecuta desde la distribucion que le quitas, un `npm install` al que se le
/// va el `_cacache` de debajo. El resultado no es una cache que se rehace, es
/// una compilacion rota con un error que no dice por que.
///
/// Se pregunta dos veces: al analizar, para avisar en la fila, y justo antes
/// de borrar cada una, porque entre una cosa y otra el usuario ha podido abrir
/// Xcode. Si no se puede saber, no se borra.
enum Occupancy: Equatable, Sendable {
    case free
    case busy(String)
    case unknown

    var isFree: Bool { self == .free }
}

/// Un programa y las rutas que usa mientras esta abierto.
///
/// El nombre es un nombre propio —Xcode, Gradle Daemon— y no se traduce.
struct Owner: Sendable {
    let name: String
    /// Patrones con `~` y `*`. Una ruta es suya si cae dentro de alguno, o si
    /// alguno cae dentro de ella.
    let paths: [String]
    /// Identificadores de apps con ventana. Un `*` final vale como prefijo.
    var apps: [String] = []
    /// Nombre del ejecutable; si lo lanza un interprete —node, python, ruby—,
    /// el del script. Sin extension: `pnpm.cjs` cuenta como `pnpm`.
    var commands: [String] = []
    /// Texto que delata al proceso en cualquiera de sus argumentos. Un daemon
    /// de Gradle es `java`, como tantos otros: lo que lo distingue es la clase.
    var arguments: [String] = []
    /// Un simulador arrancado tambien la tiene ocupada, aunque Simulator.app
    /// este cerrada.
    var simulators = false
    /// Las carpetas de los proyectos de Unity (`Library`, `Temp`, `obj`) estan
    /// a cualquier profundidad, asi que no caben en `paths`. Con esto activo,
    /// `owns` reconoce las que `FileSystem.isUnityProjectArtifact` marca.
    ///
    /// Cualquier editor de Unity abierto ocupa todos los proyectos: no hay
    /// forma fiable de saber cual tiene abierto, asi que se asume el peor caso.
    var unityProjects = false

    /// Los patrones se expanden una vez: se comparan contra cada ruta del
    /// analisis, y son cientos.
    init(name: String, paths: [String], apps: [String] = [], commands: [String] = [],
         arguments: [String] = [], simulators: Bool = false, unityProjects: Bool = false) {
        self.name = name
        self.paths = paths.map(FileSystem.expandTilde)
        self.apps = apps
        self.commands = commands
        self.arguments = arguments
        self.simulators = simulators
        self.unityProjects = unityProjects
    }

    /// Para preguntar por procesos hace falta haber podido listarlos; para
    /// preguntar por apps, no.
    var needsProcesses: Bool { !commands.isEmpty || !arguments.isEmpty || simulators }

    func owns(_ path: String) -> Bool {
        if unityProjects && FileSystem.isUnityProjectArtifact(path) { return true }
        return paths.contains { Owner.pattern($0, covers: path) }
    }

    /// `pattern` casa con `path` o con alguna carpeta que lo contiene; o, al
    /// reves, `path` contiene lo que nombra el patron.
    static func pattern(_ pattern: String, covers path: String) -> Bool {
        guard let star = pattern.firstIndex(of: "*") else {
            return path == pattern || path.hasPrefix(pattern + "/") || pattern.hasPrefix(path + "/")
        }
        // Lo de antes del primer comodin descarta casi todo sin llamar a fnmatch.
        let head = String(pattern[..<star])
        if head.hasPrefix(path + "/") { return true }
        guard path.hasPrefix(head) else { return false }
        var current = path
        while current.count >= head.count {
            if fnmatch(pattern, current, FNM_PATHNAME) == 0 { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    func isRunning(in snapshot: ProcessSnapshot) -> Occupancy {
        if snapshot.apps.contains(where: { app in apps.contains { Owner.matches(app.bundleID, $0) } }) {
            return .busy(name)
        }
        guard needsProcesses else { return .free }
        guard let processes = snapshot.processes else { return .unknown }
        if simulators && snapshot.bootedSimulator { return .busy(name) }
        for argv in processes {
            if let command = ProcessSnapshot.command(of: argv), commands.contains(command) {
                return .busy(name)
            }
            if !arguments.isEmpty,
               argv.contains(where: { arg in arguments.contains { arg.contains($0) } }) {
                return .busy(name)
            }
        }
        return .free
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        pattern.hasSuffix("*") ? value.hasPrefix(String(pattern.dropLast())) : value == pattern
    }
}

/// Lo que esta abierto en un momento dado.
struct ProcessSnapshot: Sendable {

    struct App: Sendable, Equatable {
        var bundleID: String
        /// Nombre visible, nombre del ejecutable y nombre del `.app`: una app
        /// de Electron guarda sus datos con cualquiera de los tres.
        var names: [String]
    }

    var apps: [App]
    /// Argumentos de cada proceso del usuario. nil si no se pudieron listar.
    var processes: [[String]]?
    var bootedSimulator = false

    /// Las apps hay que pedirlas en el hilo principal; los procesos no.
    @MainActor
    static func runningApps() -> [App] {
        let me = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != me, let id = app.bundleIdentifier else { return nil }
            var names: [String] = []
            if let name = app.localizedName { names.append(name) }
            if let exe = app.executableURL?.lastPathComponent { names.append(exe) }
            if let bundle = app.bundleURL?.deletingPathExtension().lastPathComponent {
                names.append(bundle)
            }
            return App(bundleID: id, names: names)
        }
    }

    static func capture(apps: [App]) -> ProcessSnapshot {
        ProcessSnapshot(apps: apps,
                        processes: Processes.commandLines(),
                        bootedSimulator: Simulators.anyBooted())
    }

    // MARK: - Nombre del programa

    private static let interpreters: Set<String> = ["php", "perl", "bash", "sh", "zsh"]
    private static let interpreterPrefixes = ["node", "python", "Python", "ruby"]
    private static let scriptExtensions = ["js", "cjs", "mjs", "py", "rb", "sh", "php"]

    /// El programa que de verdad corre. `node /opt/homebrew/bin/npm install`
    /// es npm, no node; `java ... GradleDaemon` se reconoce por argumento.
    static func command(of argv: [String]) -> String? {
        guard let first = argv.first.map(basename), !first.isEmpty else { return nil }
        let isInterpreter = interpreters.contains(first)
            || interpreterPrefixes.contains { first.hasPrefix($0) }
        guard isInterpreter else { return first }
        guard let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return first }
        return basename(script)
    }

    private static func basename(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return scriptExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    // MARK: - Ocupacion

    /// Quien tiene ocupada esta ruta, si alguien.
    func occupancy(of path: String, owners: [Owner] = Owners.all) -> Occupancy {
        var unsure = false
        for owner in owners where owner.owns(path) {
            switch owner.isRunning(in: self) {
            case .busy(let name): return .busy(name)
            case .unknown: unsure = true
            case .free: break
            }
        }
        if let app = appUsing(path) { return .busy(app) }
        return unsure ? .unknown : .free
    }

    /// Una app abierta usa su propia cache y sus propios datos, se llame como
    /// se llame: `~/Library/Caches/<su identificador o su nombre>` o
    /// `~/Library/Application Support/<lo mismo>`. Las de Electron usan el
    /// nombre en los dos sitios (`~/Library/Caches/Codex`). Sin esto, el
    /// cajon de sastre vaciaria la cache de Slack con Slack abierto.
    private func appUsing(_ path: String) -> String? {
        let library = NSHomeDirectory() + "/Library/"
        for root in ["Caches/", "Application Support/"] {
            let prefix = library + root
            guard path.hasPrefix(prefix),
                  let folder = path.dropFirst(prefix.count).split(separator: "/").first
            else { continue }
            let name = String(folder)
            for app in apps {
                let byID = name == app.bundleID || name.hasPrefix(app.bundleID + ".")
                let named = app.names.contains {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                }
                if byID || named { return app.names.first ?? app.bundleID }
            }
        }
        return nil
    }
}

// MARK: - Procesos

/// Lista de procesos con libproc, sin lanzar `ps`: no hay que esperar a otro
/// programa ni partir su salida por espacios, que en una ruta con espacios
/// se equivoca.
enum Processes {

    static func commandLines() -> [[String]]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))

        var result: [[String]] = []
        result.reserveCapacity(Int(filled))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if let argv = arguments(of: pid, buffer: &buffer) {
                result.append(argv)
            } else if let path = executablePath(of: pid) {
                // Los de otros usuarios no dejan leer sus argumentos, pero si
                // su ejecutable. Basta para reconocer la mayoria.
                result.append([path])
            }
        }
        return result
    }

    /// `KERN_PROCARGS2`: un `argc`, la ruta del ejecutable, relleno de ceros y
    /// los argumentos uno detras de otro.
    private static func arguments(of pid: pid_t, buffer: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })

        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var argv: [String] = []
        var start = index
        while index < size && argv.count < argc {
            if buffer[index] == 0 {
                argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return argv.isEmpty ? nil : argv
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }
}

// MARK: - Simuladores

enum Simulators {

    static var devicesRoot: String {
        NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices"
    }

    /// Un simulador arrancado tiene `state = 3` en su `device.plist`. Se lee
    /// del disco en vez de preguntar a `simctl`: no arranca CoreSimulator y no
    /// tarda nada.
    static func anyBooted(in root: String = devicesRoot) -> Bool {
        FileSystem.children(of: root).contains { device in
            let plist = (device as NSString).appendingPathComponent("device.plist")
            return (NSDictionary(contentsOfFile: plist)?["state"] as? Int) == 3
        }
    }
}

// MARK: - Catalogo de duenos

enum Owners {

    static let all: [Owner] = [
        // Unity. El editor es `Unity` tanto con ventana como en `-batchmode`,
        // que es como corren muchos builds de CI en la misma maquina.
        Owner(name: "Unity",
              paths: ["~/Library/Caches/Unity", "~/Library/Caches/com.unity3d.UnityEditor",
                      "~/Library/Unity", "~/Library/Logs/Unity"],
              apps: ["com.unity3d.UnityEditor*"],
              commands: ["Unity"],
              unityProjects: true),

        Owner(name: "Unity Hub",
              paths: ["~/Library/Caches/UnityHub", "~/Library/Caches/com.unity3d.unityhub*",
                      "~/Library/Application Support/UnityHub"],
              apps: ["com.unity3d.unityhub"]),

        // Xcode y lo que compila sin el: xcodebuild, swift build.
        Owner(name: "Xcode",
              paths: ["~/Library/Developer/Xcode",
                      "~/Library/Developer/XCTestDevices",
                      "~/Library/Developer/Shared/Documentation",
                      "~/Library/Caches/com.apple.dt.Xcode",
                      "~/Library/Caches/org.swift.swiftpm",
                      "~/.swiftpm"],
              apps: ["com.apple.dt.Xcode"],
              commands: ["xcodebuild", "xctest", "swift-build", "swift-package", "swift-test"]),

        Owner(name: "Simulator",
              paths: ["~/Library/Developer/CoreSimulator",
                      "~/Library/Developer/XCTestDevices",
                      "~/Library/Logs/CoreSimulator"],
              apps: ["com.apple.iphonesimulator"],
              commands: ["simctl"],
              simulators: true),

        Owner(name: "CocoaPods", paths: ["~/Library/Caches/CocoaPods"], commands: ["pod"]),
        Owner(name: "Carthage", paths: ["~/Library/Caches/org.carthage.CarthageKit"],
              commands: ["carthage"]),

        // Un daemon de Gradle se queda vivo tres horas despues de la ultima
        // compilacion, y ejecuta desde la distribucion del wrapper.
        Owner(name: "Gradle Daemon",
              paths: ["~/.gradle", "~/.android/cache", "~/.android/build-cache",
                      "~/.konan", "~/.kotlin"],
              arguments: ["org.gradle.launcher.daemon", "org.gradle.wrapper.GradleWrapperMain",
                          "org.gradle.launcher.GradleMain", "KotlinCompileDaemon"]),

        Owner(name: "Android Studio",
              paths: ["~/Library/Caches/Google/AndroidStudio*", "~/.android/cache",
                      "~/Library/Android/sdk/.temp", "~/Library/Android/sdk/temp"],
              apps: ["com.google.android.studio*"]),

        Owner(name: "JetBrains", paths: ["~/Library/Caches/JetBrains"], apps: ["com.jetbrains.*"]),

        Owner(name: "Android Emulator",
              paths: ["~/.android/avd", "~/Library/Android/sdk/system-images"],
              commands: ["emulator", "qemu-system-aarch64", "qemu-system-x86_64"]),

        Owner(name: "Maven", paths: ["~/.m2"],
              commands: ["mvn", "mvnd"],
              arguments: ["org.codehaus.plexus.classworlds.launcher"]),

        // Node y compania. Casi todos son scripts de node: se reconocen por el
        // script, no por el interprete.
        Owner(name: "npm", paths: ["~/.npm"], commands: ["npm", "npx", "npm-cli"]),
        Owner(name: "pnpm", paths: ["~/Library/pnpm", "~/.pnpm-store"], commands: ["pnpm", "pnpx"]),
        Owner(name: "Yarn", paths: ["~/Library/Caches/Yarn", "~/.cache/yarn", "~/.yarn"],
              commands: ["yarn", "yarnpkg"]),
        Owner(name: "Bun", paths: ["~/.bun"], commands: ["bun", "bunx"]),
        Owner(name: "Deno", paths: ["~/Library/Caches/deno", "~/.cache/deno"], commands: ["deno"]),
        // pnpm y yarn instalados por Corepack corren desde su cache.
        Owner(name: "Corepack", paths: ["~/.cache/node/corepack"],
              commands: ["corepack"], arguments: ["/.cache/node/corepack/"]),
        Owner(name: "node-gyp",
              paths: ["~/Library/Caches/node-gyp", "~/.node-gyp", "~/.cache/node-gyp"],
              commands: ["node-gyp"]),
        Owner(name: "TypeScript", paths: ["~/Library/Caches/typescript", "~/.cache/typescript"],
              commands: ["tsserver", "tsc"]),
        Owner(name: "ESLint", paths: ["~/.cache/eslint"], commands: ["eslint", "eslint_d"]),
        Owner(name: "Prettier", paths: ["~/.cache/prettier"], commands: ["prettier"]),
        Owner(name: "Vite", paths: ["~/.cache/vite"], commands: ["vite"]),
        Owner(name: "Prisma", paths: ["~/.cache/prisma"], commands: ["prisma"]),
        Owner(name: "Expo", paths: ["~/.expo"], commands: ["expo"], arguments: ["@expo/cli"]),
        Owner(name: "Electron Builder",
              paths: ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"],
              commands: ["electron-builder"]),
        // Los navegadores de prueba corren desde su propia carpeta.
        Owner(name: "Playwright",
              paths: ["~/Library/Caches/ms-playwright", "~/.cache/puppeteer"],
              commands: ["playwright"],
              arguments: ["/ms-playwright/", "/.cache/puppeteer/"]),

        // Otros lenguajes.
        Owner(name: "Go", paths: ["~/Library/Caches/go-build", "~/go/pkg/mod"], commands: ["go"]),
        Owner(name: "Cargo", paths: ["~/.cargo"], commands: ["cargo", "rustc"]),
        Owner(name: "pip / uv / Poetry",
              paths: ["~/Library/Caches/pip", "~/.cache/pip", "~/Library/Caches/uv",
                      "~/.cache/uv", "~/Library/Caches/pypoetry"],
              commands: ["pip", "pip3", "uv", "poetry"]),
        Owner(name: "Bundler", paths: ["~/.bundle", "~/.gem"], commands: ["bundle", "bundler", "gem"]),
        Owner(name: "Flutter", paths: ["~/.pub-cache", "~/.dartServer"], commands: ["flutter", "dart"]),
        Owner(name: "Composer", paths: ["~/.composer", "~/.cache/composer"], commands: ["composer"]),
        Owner(name: "Terraform", paths: ["~/.cache/terraform"], commands: ["terraform"]),
        Owner(name: "Bazel", paths: ["~/.cache/bazel"], commands: ["bazel", "bazelisk"]),
        Owner(name: "Zig", paths: ["~/.cache/zig"], commands: ["zig"]),
        Owner(name: "Ruff", paths: ["~/.cache/ruff"], commands: ["ruff"]),
        Owner(name: "mypy", paths: ["~/.cache/mypy"], commands: ["mypy", "dmypy"]),

        // brew es un script de bash: lo que lo delata es `brew.sh`.
        Owner(name: "Homebrew", paths: ["~/Library/Caches/Homebrew"],
              arguments: ["Homebrew/brew.sh"]),
        Owner(name: "Docker Buildx", paths: ["~/.docker/buildx"],
              commands: ["docker-buildx", "buildkitd"]),

        // Editores.
        Owner(name: "Visual Studio Code",
              paths: ["~/Library/Application Support/Code", "~/.vscode"],
              apps: ["com.microsoft.VSCode"]),
        Owner(name: "Visual Studio Code Insiders",
              paths: ["~/Library/Application Support/Code - Insiders", "~/.vscode-insiders"],
              apps: ["com.microsoft.VSCodeInsiders"]),
        Owner(name: "Cursor",
              paths: ["~/Library/Application Support/Cursor", "~/.cursor"],
              apps: ["com.todesktop.230313mzl4w4u92"]),
        Owner(name: "Windsurf",
              paths: ["~/Library/Application Support/Windsurf", "~/.windsurf"],
              apps: ["com.exafunction.windsurf"]),
        Owner(name: "VSCodium",
              paths: ["~/Library/Application Support/VSCodium", "~/.vscode-oss"],
              apps: ["com.vscodium*"]),

        // Asistentes. Una sesion de Claude Code lee sus shell-snapshots en
        // cada orden que ejecuta.
        // Instalado con el instalador nativo, cada version es un binario con
        // el numero por nombre: lanzado por su ruta, el ejecutable no se llama
        // `claude`.
        Owner(name: "Claude Code", paths: ["~/.claude"], commands: ["claude"],
              arguments: ["/.local/share/claude/versions/"]),
        Owner(name: "Claude",
              paths: ["~/Library/Application Support/Claude",
                      "~/Library/Caches/com.anthropic.claudefordesktop"],
              apps: ["com.anthropic.claudefordesktop"]),
        Owner(name: "Codex",
              paths: ["~/.codex", "~/.cache/codex-runtimes", "~/Library/Caches/com.openai.codex",
                      "~/Library/Caches/Codex", "~/Library/Application Support/Codex"],
              apps: ["com.openai.codex"],
              commands: ["codex"]),
        Owner(name: "Ollama", paths: ["~/.ollama"], apps: ["com.electron.ollama"], commands: ["ollama"]),
        Owner(name: "LM Studio", paths: ["~/.lmstudio", "~/.cache/lm-studio"],
              apps: ["ai.elementlabs.lmstudio"], commands: ["lms"]),

        // Navegadores: cerrados o nada. Con el navegador abierto, el historial
        // y las cookies son ficheros SQLite que el sigue escribiendo.
        Owner(name: "Google Chrome",
              paths: ["~/Library/Application Support/Google/Chrome",
                      "~/Library/Caches/Google/Chrome"],
              apps: ["com.google.Chrome"]),
        Owner(name: "Google Chrome Beta",
              paths: ["~/Library/Application Support/Google/Chrome Beta",
                      "~/Library/Caches/Google/Chrome Beta"],
              apps: ["com.google.Chrome.beta"]),
        Owner(name: "Google Chrome Canary",
              paths: ["~/Library/Application Support/Google/Chrome Canary",
                      "~/Library/Caches/Google/Chrome Canary"],
              apps: ["com.google.Chrome.canary"]),
        Owner(name: "Google Updater",
              paths: ["~/Library/Application Support/Google/GoogleUpdater",
                      "~/Library/Caches/com.google.Keystone"],
              commands: ["GoogleUpdater"]),
        Owner(name: "Brave",
              paths: ["~/Library/Application Support/BraveSoftware",
                      "~/Library/Caches/BraveSoftware"],
              apps: ["com.brave.Browser*"]),
        Owner(name: "Microsoft Edge",
              paths: ["~/Library/Application Support/Microsoft Edge",
                      "~/Library/Caches/Microsoft Edge"],
              apps: ["com.microsoft.edgemac*"]),
        Owner(name: "Chromium",
              paths: ["~/Library/Application Support/Chromium", "~/Library/Caches/Chromium"],
              apps: ["org.chromium.Chromium"]),
        Owner(name: "Vivaldi",
              paths: ["~/Library/Application Support/Vivaldi", "~/Library/Caches/Vivaldi"],
              apps: ["com.vivaldi.Vivaldi"]),
        Owner(name: "Firefox",
              paths: ["~/Library/Application Support/Firefox", "~/Library/Caches/Firefox",
                      "~/Library/Caches/Mozilla", "~/Library/Application Support/Mozilla"],
              apps: ["org.mozilla.firefox*", "org.mozilla.nightly"]),
        Owner(name: "LibreWolf",
              paths: ["~/Library/Application Support/LibreWolf", "~/Library/Caches/LibreWolf"],
              apps: ["io.gitlab.librewolf-community*"]),
        Owner(name: "Waterfox",
              paths: ["~/Library/Application Support/Waterfox", "~/Library/Caches/Waterfox"],
              apps: ["net.waterfox.waterfox*"]),
        Owner(name: "Zen",
              paths: ["~/Library/Application Support/zen", "~/Library/Caches/zen"],
              apps: ["app.zen-browser.zen*"]),
    ]
}
