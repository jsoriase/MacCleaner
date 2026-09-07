import Foundation
import SwiftUI

enum RowState: Equatable {
    case idle
    case scanning
    case measured
    case cleaning
    case cleaned(Int64)
    case failed(String)
}

/// Una subcarpeta de una fila desplegable: p.ej. `~/.gradle/caches/9.4.1`.
struct SubItem: Identifiable, Sendable {
    let path: String
    let name: String
    var usage = FileSystem.Usage()
    var selected = false

    var id: String { path }

    /// Medio ano sin que nadie escriba aqui. Es la senal de que esta version,
    /// ese proyecto o aquella app ya no estan en uso.
    var isStale: Bool {
        guard let date = usage.modified else { return false }
        return FileSystem.isStale(date)
    }
}

enum CheckState {
    case off, mixed, on
}

struct Row: Identifiable {
    let target: Target
    var id: String { target.id }
    var paths: [String] = []
    var usage = FileSystem.Usage()
    var selected: Bool
    var state: RowState = .idle
    /// Solo en filas desplegables. Si esta vacio, la fila se comporta como antes.
    var items: [SubItem] = []
    var expanded = false

    var isEmpty: Bool { usage.bytes == 0 }
    var hasItems: Bool { !items.isEmpty }

    /// En una fila desplegable manda la seleccion de los hijos; en una normal,
    /// la casilla de la propia fila.
    var anySelected: Bool {
        hasItems ? items.contains(where: \.selected) : selected
    }

    var checkState: CheckState {
        guard hasItems else { return selected ? .on : .off }
        if items.allSatisfy(\.selected) { return .on }
        return items.contains(where: \.selected) ? .mixed : .off
    }

    var selectedBytes: Int64 {
        hasItems
            ? items.filter(\.selected).reduce(0) { $0 + $1.usage.bytes }
            : (selected ? usage.bytes : 0)
    }

    /// Rutas que se borrarian ahora mismo, segun lo que este marcado.
    var victims: (paths: [String], scope: Scope) {
        guard hasItems else { return (paths, target.scope) }
        let chosen = items.filter(\.selected).map(\.path)
        // Con .children el item es un hijo del target y se borra entero; con
        // .paths el item es el target mismo, asi que se respeta su scope para
        // no convertir un "vaciar" en un "borrar la carpeta".
        return (chosen, target.expansion == .paths ? target.scope : .item)
    }
}

@MainActor
final class Engine: ObservableObject {

    @Published private(set) var rows: [Row]
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var progress = 0.0
    @Published private(set) var currentStep = ""
    @Published private(set) var lastReport: Report?
    @Published var useTrash = false
    @Published var hideEmpty = true
    /// Espacio del disco donde vive el home. Se refresca al arrancar y despues
    /// de cada limpieza, para ver como sube el hueco libre.
    @Published private(set) var volume: FileSystem.Volume?

    struct Report {
        var freed: Int64
        var cleaned: Int
        var failures: [String]
    }

    private var work: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        let store = UserDefaults.standard
        // La seleccion no se recuerda a proposito: cada sesion empieza sin nada
        // marcado, para que borrar sea siempre una decision deliberada.
        // Se limpian de paso las claves que dejaron versiones anteriores.
        for key in store.dictionaryRepresentation().keys
        where key.hasPrefix("select.") || key == "selectionSchema" {
            store.removeObject(forKey: key)
        }
        rows = Catalog.targets.map { Row(target: $0, selected: false) }
        useTrash = store.bool(forKey: "useTrash")
        volume = FileSystem.homeVolume()
    }

    func refreshVolume() {
        volume = FileSystem.homeVolume()
    }

    // MARK: - Derivados para la UI

    var selectedBytes: Int64 {
        rows.reduce(0) { $0 + $1.selectedBytes }
    }

    var selectedCount: Int {
        rows.filter { $0.anySelected && !$0.isEmpty }.count
    }

    var anySelected: Bool {
        rows.contains(where: \.anySelected)
    }

    var foundBytes: Int64 {
        rows.reduce(0) { $0 + $1.usage.bytes }
    }

    func rows(in group: Category) -> [Row] {
        rows.filter { row in
            guard row.target.group == group else { return false }
            if hideEmpty && hasScanned && row.isEmpty && !row.anySelected { return false }
            return true
        }
    }

    func groupBytes(_ group: Category) -> Int64 {
        rows.filter { $0.target.group == group }.reduce(0) { $0 + $1.usage.bytes }
    }

    // MARK: - Seleccion

    func setSelected(_ id: String, _ value: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].selected = value
        for j in rows[i].items.indices { rows[i].items[j].selected = value }
    }

    /// Marca o desmarca una subcarpeta suelta.
    func setItemSelected(_ rowID: String, _ path: String, _ value: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == rowID }),
              let j = rows[i].items.firstIndex(where: { $0.path == path }) else { return }
        rows[i].items[j].selected = value
        rows[i].selected = rows[i].items.contains(where: \.selected)
    }

    func toggleExpanded(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].expanded.toggle()
    }

    /// Alterna la fila entera: si algo esta marcado lo desmarca todo, si no marca todo.
    func toggleRow(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        setSelected(id, rows[i].checkState != .on)
    }

    /// Filas candidatas de un nivel de riesgo: una vez analizado, solo las que
    /// tienen algo que borrar; antes de analizar, todas.
    private func candidates(for risk: Risk) -> [Row] {
        rows.filter { $0.target.risk == risk && (!hasScanned || !$0.isEmpty) }
    }

    func bytes(for risk: Risk) -> Int64 {
        candidates(for: risk).reduce(0) { $0 + $1.usage.bytes }
    }

    func allSelected(for risk: Risk) -> Bool {
        let group = candidates(for: risk)
        return !group.isEmpty && group.allSatisfy { $0.checkState == .on }
    }

    /// Marca todas las filas de ese riesgo, o las desmarca si ya lo estaban.
    /// Al ser acumulativo puedes combinar niveles: Seguras + Se regeneran.
    func toggleRisk(_ risk: Risk) {
        let group = candidates(for: risk)
        guard !group.isEmpty else { return }
        let turnOn = !group.allSatisfy { $0.checkState == .on }
        for row in group { setSelected(row.id, turnOn) }
    }

    func clearSelection() {
        for index in rows.indices where rows[index].anySelected {
            setSelected(rows[index].id, false)
        }
    }

    func selectAll(in group: Category, _ value: Bool) {
        for i in rows.indices where rows[i].target.group == group {
            setSelected(rows[i].id, value)
        }
    }

    func persistTrashPreference() {
        defaults.set(useTrash, forKey: "useTrash")
    }

    // MARK: - Analisis

    func scan() {
        guard !isScanning && !isCleaning else { return }
        work?.cancel()
        isScanning = true
        progress = 0
        lastReport = nil
        for i in rows.indices {
            rows[i].usage = FileSystem.Usage()
            rows[i].state = .idle
        }

        work = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
            self.isScanning = false
            self.hasScanned = true
            self.currentStep = ""
            self.progress = 1
        }
    }

    func cancel() {
        work?.cancel()
    }

    private func runScan() async {
        currentStep = "Localizando rutas…"

        // 1. Expandir patrones (rapido, pero fuera del hilo principal).
        let targets = rows.map(\.target)
        let expanded: [String: [String]] = await Task.detached(priority: .userInitiated) {
            var map: [String: [String]] = [:]
            var claimed: [String] = []
            // Primero los targets concretos, para saber que rutas ya estan cubiertas.
            for target in targets where !target.isCatchAll {
                let paths = target.patterns
                    .flatMap { FileSystem.expand($0) }
                    .filter { !FileSystem.isProtected($0) }
                map[target.id] = paths
                claimed.append(contentsOf: paths)
            }
            // Los "cajon de sastre" descartan lo que ya cubre otra fila.
            for target in targets where target.isCatchAll {
                let paths = target.patterns.flatMap { FileSystem.expand($0) }
                map[target.id] = paths.filter { path in
                    guard !FileSystem.isProtected(path) else { return false }
                    return !claimed.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
                }
            }
            return map
        }.value

        guard !Task.isCancelled else { return }

        for i in rows.indices {
            rows[i].paths = expanded[rows[i].id] ?? []
            if rows[i].paths.isEmpty { rows[i].state = .measured }
        }

        // 2. Medir tamanos en paralelo. Es trabajo de disco, no de CPU:
        //    unos pocos hilos saturan el SSD y mantienen la RAM plana.
        let pending = rows.filter { !$0.paths.isEmpty }
            .map { ($0.id, $0.paths, $0.target.expansion) }
        let total = max(pending.count, 1)
        var done = 0
        let lanes = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

        await withTaskGroup(of: (String, FileSystem.Usage, [SubItem]).self) { group in
            var iterator = pending.makeIterator()

            func addNext() {
                guard let (id, paths, expansion) = iterator.next() else { return }
                group.addTask(priority: .userInitiated) {
                    // Las filas desplegables se miden trozo a trozo: el mismo
                    // recorrido de siempre, pero guardando el desglose.
                    guard expansion != .none else {
                        var sum = FileSystem.Usage()
                        for path in paths {
                            if Task.isCancelled { break }
                            sum = sum + FileSystem.usage(of: path) { Task.isCancelled }
                        }
                        return (id, sum, [])
                    }

                    let pieces = expansion == .paths
                        ? paths
                        : paths.flatMap { FileSystem.children(of: $0) }

                    var items: [SubItem] = []
                    items.reserveCapacity(pieces.count)
                    for piece in pieces {
                        if Task.isCancelled { break }
                        let usage = FileSystem.usage(of: piece) { Task.isCancelled }
                        items.append(SubItem(path: piece,
                                             name: (piece as NSString).lastPathComponent,
                                             usage: usage))
                    }
                    items.sort { $0.usage.bytes > $1.usage.bytes }
                    let sum = items.reduce(FileSystem.Usage()) { $0 + $1.usage }
                    return (id, sum, items)
                }
            }

            for _ in 0..<lanes { addNext() }

            for await (id, usage, items) in group {
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].usage = usage
                    // Se conserva lo que el usuario ya hubiera marcado antes.
                    let previouslyOn = Set(rows[i].items.filter(\.selected).map(\.path))
                    rows[i].items = items.map { item in
                        var copy = item
                        copy.selected = previouslyOn.contains(item.path) || rows[i].selected
                        return copy
                    }
                    rows[i].state = .measured
                    currentStep = rows[i].target.name
                }
                done += 1
                progress = Double(done) / Double(total)
                if Task.isCancelled { group.cancelAll(); break }
                addNext()
            }
        }
    }

    // MARK: - Limpieza

    func clean() {
        guard !isScanning && !isCleaning else { return }
        let plan = rows.filter { $0.anySelected && !$0.isEmpty }
        guard !plan.isEmpty else { return }

        isCleaning = true
        progress = 0
        let trash = useTrash

        work = Task { [weak self] in
            guard let self else { return }
            var freed: Int64 = 0
            var cleaned = 0
            var failures: [String] = []

            for (index, row) in plan.enumerated() {
                if Task.isCancelled { break }
                self.mark(row.id, .cleaning)
                self.currentStep = row.target.name

                let (paths, scope) = row.victims
                let result = await Task.detached(priority: .userInitiated) {
                    Engine.erase(paths: paths, scope: scope, toTrash: trash)
                }.value

                let recovered = max(0, row.selectedBytes - result.failedBytes)
                if result.errors.isEmpty {
                    self.mark(row.id, .cleaned(recovered))
                } else {
                    self.mark(row.id, .failed(result.errors[0]))
                    failures.append("\(row.target.name): \(result.errors[0])")
                }
                freed += recovered
                if recovered > 0 { cleaned += 1 }
                self.dropCleanedItems(row.id, failedBytes: result.failedBytes)
                self.progress = Double(index + 1) / Double(plan.count)
            }

            self.lastReport = Report(freed: freed, cleaned: cleaned, failures: failures)
            self.isCleaning = false
            self.currentStep = ""
            self.refreshVolume()
        }
    }

    private func mark(_ id: String, _ state: RowState) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = state
    }

    /// Deja la fila reflejando lo que queda: se van las subcarpetas borradas y
    /// el tamano baja a lo que no se pudo eliminar.
    private func dropCleanedItems(_ id: String, failedBytes: Int64) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].hasItems {
            rows[i].items.removeAll(where: \.selected)
            rows[i].usage = rows[i].items.reduce(FileSystem.Usage()) { $0 + $1.usage }
            if failedBytes > 0 { rows[i].usage.bytes += failedBytes }
        } else {
            rows[i].usage = FileSystem.Usage(bytes: failedBytes, files: 0)
        }
        rows[i].selected = rows[i].items.contains(where: \.selected)
    }

    // MARK: - Borrado real (fuera del hilo principal)

    struct EraseResult: Sendable {
        var removed = 0
        var failedBytes: Int64 = 0
        var errors: [String] = []
    }

    nonisolated static func erase(paths: [String], scope: Scope, toTrash: Bool) -> EraseResult {
        var result = EraseResult()

        for path in paths {
            guard isSafe(path), !FileSystem.isProtected(path) else {
                result.errors.append("ruta protegida: \(FileSystem.prettyPath(path))")
                continue
            }

            let victims: [String] = (scope == .contents && FileSystem.isDirectory(path))
                ? FileSystem.children(of: path)
                : [path]

            for victim in victims {
                if Task.isCancelled { return result }
                guard isSafe(victim), !FileSystem.isProtected(victim) else { continue }
                do {
                    try FileSystem.remove(victim, toTrash: toTrash)
                    result.removed += 1
                } catch {
                    // Solo medimos lo que NO se ha podido borrar. En el caso normal
                    // (todo se borra) nos ahorramos recorrer el arbol una segunda vez.
                    result.failedBytes += FileSystem.usage(of: victim).bytes
                    let reason = (error as NSError).localizedFailureReason
                        ?? error.localizedDescription
                    if result.errors.count < 5 { result.errors.append(reason) }
                }
            }
        }
        return result
    }

    /// Carpetas de primer nivel del home que no deben borrarse enteras jamas,
    /// por mucho que un patron del catalogo acabe apuntando a ellas.
    private nonisolated static let untouchableTopLevel: Set<String> = [
        "Library", "Documents", "Desktop", "Downloads", "Pictures", "Music",
        "Movies", "Public", "Applications", "Developer", "Sites",
    ]

    /// Red de seguridad: fuera del home no se toca nada, y dentro del home
    /// las carpetas de primer nivel del sistema quedan excluidas.
    /// Carpetas propias de una herramienta (~/.Trash, ~/.pnpm-store) si se aceptan:
    /// son justo las que algunos targets necesitan vaciar.
    nonisolated static func isSafe(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let normalized = (path as NSString).standardizingPath
        guard normalized.hasPrefix(home + "/") else { return false }
        let relative = String(normalized.dropFirst(home.count + 1))
        guard !relative.isEmpty else { return false }
        let components = (relative as NSString).pathComponents
        if components.count == 1 { return !untouchableTopLevel.contains(components[0]) }
        return true
    }
}
