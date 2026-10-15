import Foundation
import SwiftUI
import os

enum RowState: Equatable {
    case idle
    case scanning
    case measured
    case cleaning
    case cleaned(Int64)
    case failed(String)
    /// No se ha tocado nada, y este es el motivo: en uso, o cambiada desde
    /// el analisis.
    case skipped(String)
}

/// Una subcarpeta de una fila desplegable: p.ej. `~/.gradle/caches/9.4.1`.
struct SubItem: Identifiable, Sendable {
    let path: String
    let name: String
    /// Cuando el nombre de la carpeta no dice nada —el UDID de un simulador—,
    /// aqui viene el que si: "iPhone 17 Pro · iOS 26.5".
    var label: String? = nil
    var usage = FileSystem.Usage()
    var selected = false

    var id: String { path }

    var title: String { label ?? name }

    /// Medio ano sin que nadie escriba aqui. Es la senal de que esta version,
    /// ese proyecto o aquella app ya no estan en uso.
    var isStale: Bool {
        guard let date = usage.modified else { return false }
        return FileSystem.isStale(date)
    }

    /// Escrita esta semana. En un artefacto de proyecto es la senal de que
    /// puede ser el del proyecto en el que estas.
    var isRecent: Bool {
        guard let date = usage.modified else { return false }
        return FileSystem.isRecent(date)
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
    /// Como estaba cada ruta al analizarla: cuanto ocupaba y que objeto era.
    /// Antes de borrar se compara con lo que hay, y lo que se apunta en el
    /// historial sale de aqui.
    var records: [String: Record] = [:]

    struct Record: Sendable {
        var bytes: Int64
        var identity: FileSystem.Identity?
    }

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

    // MARK: Seleccion de golpe

    /// Lo que entra al marcar de golpe: botones de riesgo, «Todo» del grupo y
    /// la casilla de la fila. Un artefacto de proyecto escrito esta semana no:
    /// puede ser el `node_modules` del proyecto que tienes abierto. Sigue
    /// pudiendo marcarse a mano, uno a uno.
    func isBulkEligible(_ item: SubItem) -> Bool {
        !(target.isSweep && item.isRecent)
    }

    /// Como la casilla, pero contando solo lo que entra de golpe.
    var bulkCheckState: CheckState {
        guard hasItems else { return selected ? .on : .off }
        let eligible = items.filter(isBulkEligible)
        if !eligible.isEmpty && eligible.allSatisfy(\.selected) { return .on }
        return items.contains(where: \.selected) ? .mixed : .off
    }

    var bulkBytes: Int64 {
        hasItems
            ? items.filter(isBulkEligible).reduce(0) { $0 + $1.usage.bytes }
            : usage.bytes
    }

    /// Marca de golpe: todo lo que entra, o nada.
    mutating func setAll(_ value: Bool) {
        selected = value
        for j in items.indices {
            items[j].selected = value && isBulkEligible(items[j])
        }
        if hasItems { selected = items.contains(where: \.selected) }
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

    /// Pone el desglose recien medido sin perder lo que el usuario ya habia
    /// marcado.
    ///
    /// Si ya habia desglose, manda la marca de cada subcarpeta. La de la fila
    /// no sirve: solo dice que hay *algo* marcado, y tomarla por «todo» hacia
    /// que marcar una version de Gradle y volver a analizar las marcara todas.
    /// Si no lo habia —marcada por riesgo antes del primer analisis—, la fila
    /// entera es la eleccion.
    mutating func adopt(_ measured: [SubItem]) {
        let previouslyOn: Set<String>? = hasItems
            ? Set(items.filter(\.selected).map(\.path))
            : nil
        items = measured.map { item in
            var copy = item
            copy.selected = previouslyOn?.contains(item.path) ?? (selected && isBulkEligible(item))
            return copy
        }
        if previouslyOn != nil { selected = items.contains(where: \.selected) }
    }

    /// Deja la fila como ha quedado despues de borrar.
    ///
    /// `leftover` es lo que sigue ocupando cada ruta que se intento borrar. Una
    /// subcarpeta que no se pudo borrar —o a la que no se llego porque se
    /// detuvo la limpieza— se queda en la lista con lo que ocupa ahora, y sin
    /// marcar: volver a intentarlo es otra decision.
    mutating func settle(leftover: [String: Int64]) {
        if hasItems {
            items = items.compactMap { item in
                guard item.selected else { return item }
                guard let left = leftover[item.path], left > 0 else { return nil }
                var copy = item
                copy.usage.bytes = left
                copy.selected = false
                return copy
            }
            usage = items.reduce(FileSystem.Usage()) { $0 + $1.usage }
        } else {
            usage = FileSystem.Usage(bytes: leftover.values.reduce(0, +), files: 0)
        }
        selected = false
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
    @Published var useTrash = true
    @Published var hideEmpty = true
    /// Espacio del disco donde vive el home. Se refresca al arrancar y despues
    /// de cada limpieza, para ver como sube el hueco libre.
    @Published private(set) var volume: FileSystem.Volume?
    /// Rutas que algun programa abierto esta usando. Solo las que no estan
    /// libres: es lo que se pinta en la lista.
    @Published private(set) var occupancy: [String: Occupancy] = [:]
    /// Lo que el usuario ha pedido no volver a ver. Se recuerda entre sesiones.
    @Published private(set) var ignoredRows: Set<String> = []
    @Published private(set) var ignoredPaths: Set<String> = []
    /// Carpetas de codigo que el usuario ha anadido. Incluye las que hoy no
    /// estan disponibles: la hoja las muestra marcadas.
    @Published private(set) var userCodeRoots: [String] = []
    /// La hoja de carpetas de codigo, abierta desde el menu.
    @Published var showingCodeRoots = false

    struct Report {
        var freed: Int64
        var cleaned: Int
        var failures: [String]
        /// Mover a la Papelera no libera nada hasta vaciarla, asi que el informe
        /// no puede llamarlo «liberado». Se guarda aqui y no se lee de la
        /// casilla: el usuario puede cambiarla despues de limpiar.
        var toTrash: Bool = false
        /// Lo que no se toco, con su motivo. No es un fallo: es la app
        /// negandose a borrar algo que estaba en uso o habia cambiado.
        var skipped: [String] = []
        /// Hueco libre antes de empezar, para ensenar cuanto ha subido.
        var freeBefore: Int64? = nil
    }

    private var work: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Cuando empezo el ultimo analisis. Un artefacto de proyecto escrito
    /// despues ya no es el que se aprobo.
    private var scannedAt: Date?

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
        // Mientras nadie diga lo contrario, a la Papelera: es lo unico que
        // tiene vuelta atras. `bool(forKey:)` no sirve aqui, porque sin clave
        // devuelve `false` y la primera limpieza seria para siempre.
        useTrash = store.object(forKey: "useTrash") as? Bool ?? true
        ignoredRows = Set(store.stringArray(forKey: Engine.ignoredRowsKey) ?? [])
        ignoredPaths = Set(store.stringArray(forKey: Engine.ignoredPathsKey) ?? [])
        userCodeRoots = CodeRoots.stored(store)
        volume = FileSystem.homeVolume()
    }

    // MARK: - Carpetas de codigo

    /// Anade una carpeta de codigo propia. Si se rechaza, devuelve el motivo.
    /// No hace nada mientras se analiza o se limpia: el analisis en curso ya
    /// tiene decididas sus rutas, y la lista se aplica en el siguiente.
    func addCodeRoot(_ path: String) -> CodeRoots.Rejection? {
        guard !isScanning && !isCleaning else { return nil }
        let rejection = CodeRoots.add(path, to: defaults)
        userCodeRoots = CodeRoots.stored(defaults)
        return rejection
    }

    /// Quita una carpeta de la lista. Tampoco mientras hay un analisis o una
    /// limpieza en marcha.
    func removeCodeRoot(_ path: String) {
        guard !isScanning && !isCleaning else { return }
        CodeRoots.remove(path, from: defaults)
        userCodeRoots = CodeRoots.stored(defaults)
    }

    func refreshVolume() {
        volume = FileSystem.homeVolume()
    }

    /// Vuelve a mirar el hueco libre durante unos segundos despues de borrar.
    ///
    /// APFS no devuelve los bloques de golpe: liquidar un arbol de decenas de
    /// miles de ficheros se termina en segundo plano, y `simctl` hace ademas su
    /// propia limpieza. Leer el volumen justo al acabar da siempre de menos —en
    /// una prueba, 13 GB de los 20 borrados— y hace parecer que la cifra miente
    /// cuando lo unico que pasa es que el sistema aun no ha acabado.
    ///
    /// Se para en cuanto dos lecturas seguidas coinciden, o a los 12 segundos.
    private func settleVolume() {
        settling?.cancel()
        settling = Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let before = self.volume
                self.refreshVolume()
                if self.volume == before { return }
            }
        }
    }

    // MARK: - En uso

    /// Vuelve a mirar que programas estan abiertos y que rutas tienen. Se
    /// llama al acabar un analisis o una limpieza y al volver a la app: el
    /// usuario puede haber cerrado Xcode para poder limpiar.
    func refreshOccupancy() {
        guard hasScanned else { return }
        let apps = ProcessSnapshot.runningApps()
        let paths = rows
            .filter { $0.target.reclaim == nil && !ignoredRows.contains($0.id) }
            .flatMap { $0.hasItems ? $0.items.map(\.path) : $0.paths }
        watching?.cancel()
        watching = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: Occupancy] in
                let snapshot = ProcessSnapshot.capture(apps: apps)
                var map: [String: Occupancy] = [:]
                for path in paths {
                    let state = snapshot.occupancy(of: path)
                    if state != .free { map[path] = state }
                }
                return map
            }.value
            guard let self, !Task.isCancelled else { return }
            self.occupancy = found
        }
    }

    /// De una fila entera: la primera ruta ocupada manda.
    func occupancy(of row: Row) -> Occupancy {
        var unsure = false
        for path in row.hasItems ? row.items.map(\.path) : row.paths {
            switch occupancy[path] {
            case .busy(let name)?: return .busy(name)
            case .unknown?: unsure = true
            default: break
            }
        }
        return unsure ? .unknown : .free
    }

    func occupancy(ofItem path: String) -> Occupancy {
        occupancy[path] ?? .free
    }

    // MARK: - Derivados para la UI

    private var visibleRows: [Row] {
        rows.filter { !ignoredRows.contains($0.id) }
    }

    var selectedBytes: Int64 {
        visibleRows.reduce(0) { $0 + $1.selectedBytes }
    }

    var selectedCount: Int {
        visibleRows.filter { $0.anySelected && !$0.isEmpty }.count
    }

    var anySelected: Bool {
        visibleRows.contains(where: \.anySelected)
    }

    var foundBytes: Int64 {
        visibleRows.reduce(0) { $0 + $1.usage.bytes }
    }

    func rows(in group: Category) -> [Row] {
        visibleRows.filter { row in
            guard row.target.group == group else { return false }
            return !(hideEmpty && hasScanned && isHideable(row))
        }
    }

    /// Vacia de verdad: medida y sin nada. La que no se llego a medir —porque
    /// se detuvo el analisis— no esta vacia, esta sin medir; y la que se acaba
    /// de limpiar tiene que poder ensenar lo que ha liberado. Mientras se
    /// analiza se ocultan todas las que aun no tienen cifra, como siempre,
    /// para que la lista no de saltos.
    private func isHideable(_ row: Row) -> Bool {
        guard row.isEmpty, !row.anySelected else { return false }
        return isScanning || row.state == .measured
    }

    func groupBytes(_ group: Category) -> Int64 {
        visibleRows.filter { $0.target.group == group }.reduce(0) { $0 + $1.usage.bytes }
    }

    /// Para la barra lateral: lo marcado en una categoria no se ve mientras
    /// se mira otra, pero el boton de limpiar lo va a borrar igual.
    func anySelected(in group: Category) -> Bool {
        visibleRows.contains { $0.target.group == group && $0.anySelected }
    }

    func isBusy(_ group: Category) -> Bool {
        rows.contains { $0.target.group == group && ($0.state == .scanning || $0.state == .cleaning) }
    }

    // MARK: - Seleccion

    /// Marca o desmarca la fila entera, de golpe: lo reciente de un barrido
    /// de proyectos no entra (ver `Row.isBulkEligible`).
    func setSelected(_ id: String, _ value: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].setAll(value)
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

    /// Alterna la fila entera: si ya esta todo lo que entra de golpe, la
    /// desmarca; si no, lo marca.
    func toggleRow(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        setSelected(id, rows[i].bulkCheckState != .on)
    }

    /// Filas candidatas de un nivel de riesgo: una vez analizado, solo las que
    /// tienen algo que borrar de golpe; antes de analizar, todas. Con una
    /// categoria, solo las suyas: los botones actuan sobre lo que se esta viendo.
    private func candidates(for risk: Risk, in category: Category?) -> [Row] {
        visibleRows.filter {
            $0.target.risk == risk && (!hasScanned || $0.bulkBytes > 0)
                && (category == nil || $0.target.group == category)
        }
    }

    func bytes(for risk: Risk, in category: Category? = nil) -> Int64 {
        candidates(for: risk, in: category).reduce(0) { $0 + $1.bulkBytes }
    }

    func allSelected(for risk: Risk, in category: Category? = nil) -> Bool {
        let group = candidates(for: risk, in: category)
        return !group.isEmpty && group.allSatisfy { $0.bulkCheckState == .on }
    }

    /// Marca todas las filas de ese riesgo, o las desmarca si ya lo estaban.
    /// Al ser acumulativo puedes combinar niveles: Seguras + Se regeneran.
    func toggleRisk(_ risk: Risk, in category: Category? = nil) {
        let group = candidates(for: risk, in: category)
        guard !group.isEmpty else { return }
        let turnOn = !group.allSatisfy { $0.bulkCheckState == .on }
        for row in group { setSelected(row.id, turnOn) }
    }

    func clearSelection() {
        for index in rows.indices where rows[index].anySelected {
            setSelected(rows[index].id, false)
        }
    }

    func selectAll(in group: Category, _ value: Bool) {
        for row in visibleRows where row.target.group == group {
            setSelected(row.id, value)
        }
    }

    func persistTrashPreference() {
        defaults.set(useTrash, forKey: "useTrash")
    }

    // MARK: - No volver a ofrecer

    static let ignoredRowsKey = "ignored.rows"
    static let ignoredPathsKey = "ignored.paths"

    var ignoredCount: Int { ignoredRows.count + ignoredPaths.count }

    /// La fila entera desaparece de la lista, y no se vuelve a medir.
    func ignoreRow(_ id: String) {
        setSelected(id, false)
        ignoredRows.insert(id)
        defaults.set(Array(ignoredRows).sorted(), forKey: Engine.ignoredRowsKey)
    }

    /// Una ruta suelta —una subcarpeta, o una de las rutas de una fila— deja
    /// de contar, y con ella todo lo que tenga dentro.
    func ignorePath(_ path: String, in rowID: String) {
        ignoredPaths.insert(path)
        defaults.set(Array(ignoredPaths).sorted(), forKey: Engine.ignoredPathsKey)
        guard let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[i].items.removeAll { Engine.isIgnored($0.path, in: ignoredPaths) }
        rows[i].paths.removeAll { Engine.isIgnored($0, in: ignoredPaths) }
        if rows[i].hasItems {
            rows[i].usage = rows[i].items.reduce(FileSystem.Usage()) { $0 + $1.usage }
            rows[i].selected = rows[i].items.contains(where: \.selected)
        } else {
            rows[i].usage.bytes = rows[i].paths.reduce(0) { $0 + (rows[i].records[$1]?.bytes ?? 0) }
        }
    }

    /// Vuelve a ofrecerlo todo. Lo que estaba oculto necesita otro analisis
    /// para tener cifra, asi que se lanza.
    func unignoreAll() {
        ignoredRows = []
        ignoredPaths = []
        defaults.removeObject(forKey: Engine.ignoredRowsKey)
        defaults.removeObject(forKey: Engine.ignoredPathsKey)
        if hasScanned { scan() }
    }

    nonisolated static func isIgnored(_ path: String, in ignored: Set<String>) -> Bool {
        ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Analisis

    func scan() {
        guard !isScanning && !isCleaning else { return }
        work?.cancel()
        settling?.cancel()
        isScanning = true
        progress = 0
        lastReport = nil
        scannedAt = Date()
        // «Volver a analizar» es lo que pulsa cualquiera para ver el estado de
        // ahora, asi que el hueco libre tiene que venir de ahora tambien. Sin
        // esto se quedaba con la lectura del final de la ultima limpieza —el
        // peor instante posible— y no habia forma de sacarlo de ahi sin cerrar
        // la app.
        refreshVolume()
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
            self.refreshOccupancy()
        }
    }

    func cancel() {
        work?.cancel()
        settling?.cancel()
    }

    private func runScan() async {
        currentStep = "Localizando rutas…"

        // 1. Expandir patrones (rapido, pero fuera del hilo principal). Lo
        //    ignorado se descarta despues de repartir: si se quitara antes, el
        //    cajon de sastre se quedaria con lo que el usuario ha ignorado en
        //    otra fila.
        let targets = rows.filter { !ignoredRows.contains($0.id) }.map(\.target)
        let expanded: [String: [String]] = await Task.detached(priority: .userInitiated) {
            Engine.resolve(targets)
        }.value

        guard !Task.isCancelled else { return }

        let ignored = ignoredPaths
        for i in rows.indices {
            rows[i].paths = (expanded[rows[i].id] ?? []).filter { !Engine.isIgnored($0, in: ignored) }
            rows[i].records = [:]
            if rows[i].paths.isEmpty { rows[i].state = .measured }
        }

        // 2. Medir tamanos en paralelo. Es trabajo de disco, no de CPU:
        //    unos pocos hilos saturan el SSD y mantienen la RAM plana.
        let pending = rows.filter { !$0.paths.isEmpty }.map { ($0.id, $0.paths, $0.target) }
        let total = max(pending.count, 1)
        var done = 0
        let lanes = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

        typealias Measured = (id: String, usage: FileSystem.Usage, items: [SubItem],
                              records: [String: Row.Record])

        await withTaskGroup(of: Measured.self) { group in
            var iterator = pending.makeIterator()

            /// Devuelve la fila que se ha puesto a medir, para marcarla desde
            /// fuera: a una funcion local no le llega el aislamiento del hilo
            /// principal, y sin el no puede tocar `rows`.
            func addNext() -> String? {
                guard let (id, paths, target) = iterator.next() else { return nil }
                group.addTask(priority: .userInitiated) {
                    Engine.measure(id: id, paths: paths, target: target, ignored: ignored)
                }
                return id
            }

            for _ in 0..<lanes {
                if let id = addNext() { mark(id, .scanning) }
            }

            for await measured in group {
                if let i = rows.firstIndex(where: { $0.id == measured.id }) {
                    rows[i].usage = measured.usage
                    rows[i].adopt(measured.items)
                    rows[i].records = measured.records
                    rows[i].state = .measured
                    currentStep = rows[i].target.name
                }
                done += 1
                progress = Double(done) / Double(total)
                if Task.isCancelled { group.cancelAll(); break }
                if let id = addNext() { mark(id, .scanning) }
            }
        }

        // Detenido a medias: lo que estaba midiendose no tiene cifra.
        for i in rows.indices where rows[i].state == .scanning {
            rows[i].state = .idle
        }
    }

    /// Mide una fila. Las desplegables se miden trozo a trozo: el mismo
    /// recorrido de siempre, pero guardando el desglose.
    nonisolated private static func measure(
        id: String, paths: [String], target: Target, ignored: Set<String>
    ) -> (id: String, usage: FileSystem.Usage, items: [SubItem], records: [String: Row.Record]) {
        var records: [String: Row.Record] = [:]

        // Los runtimes no se recorren: son imagenes montadas, y lo que ocupan
        // en disco lo sabe simctl, que ya lo dijo al listarlos.
        if target.reclaim == .runtime {
            let items: [SubItem] = paths.compactMap { path in
                guard let runtime = SimRuntimes.cached(at: path) else { return nil }
                let used = runtime.lastUsed.map { time_t($0.timeIntervalSince1970) } ?? 0
                records[path] = Row.Record(bytes: runtime.bytes, identity: nil)
                return SubItem(path: path, name: runtime.title, label: runtime.title,
                               usage: FileSystem.Usage(bytes: runtime.bytes, files: 0, newest: used))
            }
            let sum = items.reduce(FileSystem.Usage()) { $0 + $1.usage }
            return (id, sum, items, records)
        }

        // El disco de Docker tampoco se pesa: lo que ocupa no es lo que el
        // prune devuelve. Se ofrece lo que Docker dice que se llevaria, y con
        // Docker cerrado, nada, porque sin el no hay prune que lanzar. Va
        // entero en la primera ruta: es una cifra de Docker, no de un fichero.
        if target.reclaim == .docker {
            let bytes = paths.isEmpty ? 0 : DockerPrune.prunable() ?? 0
            for (index, path) in paths.enumerated() {
                records[path] = Row.Record(bytes: index == 0 ? bytes : 0, identity: nil)
            }
            return (id, FileSystem.Usage(bytes: bytes, files: 0), [], records)
        }

        guard target.expansion != .none else {
            var sum = FileSystem.Usage()
            for path in paths {
                if Task.isCancelled { break }
                let usage = FileSystem.usage(of: path) { Task.isCancelled }
                records[path] = Row.Record(bytes: usage.bytes, identity: FileSystem.identity(of: path))
                sum = sum + usage
            }
            return (id, sum, [], records)
        }

        let pieces = (target.expansion == .paths
            ? paths
            : paths.flatMap { FileSystem.children(of: $0) })
            .filter { !isIgnored($0, in: ignored) }

        var items: [SubItem] = []
        items.reserveCapacity(pieces.count)
        for piece in pieces {
            if Task.isCancelled { break }
            let usage = FileSystem.usage(of: piece) { Task.isCancelled }
            records[piece] = Row.Record(bytes: usage.bytes, identity: FileSystem.identity(of: piece))
            items.append(SubItem(path: piece,
                                 name: (piece as NSString).lastPathComponent,
                                 label: Engine.label(for: piece, naming: target.naming),
                                 usage: usage))
        }
        let sum = items.reduce(FileSystem.Usage()) { $0 + $1.usage }
        // Las que no ocupan nada no se ensenan: no hay nada que
        // recuperar en ellas y ahogan el desglose. Un patron como
        // ~/Library/Application Support/*/Cache encuentra decenas
        // de carpetas y solo un punado tiene contenido.
        items.removeAll { $0.usage.bytes == 0 }
        items.sort { $0.usage.bytes > $1.usage.bytes }
        return (id, sum, items, records)
    }

    /// Las rutas de cada fila, ya sin las protegidas y sin solapes.
    ///
    /// Vive aparte del analisis para poder comprobarla: que una ruta no acabe
    /// contada en dos filas es lo que separa un total honesto de uno inflado, y
    /// eso no se ve mirando una fila sola.
    ///
    /// `expand` es de donde salen las rutas de cada fila. Fuera de los tests
    /// es el disco; en ellos, un disco inventado con los casos que interesan,
    /// para no depender de lo que haya instalado en la maquina que los corre.
    nonisolated static func resolve(
        _ targets: [Target],
        expand: (Target) -> [String] = { $0.resolvePaths() }
    ) -> [String: [String]] {
        var map: [String: [String]] = [:]
        var claimed: [String] = []

        // Primero los targets concretos, para saber que rutas ya estan cubiertas.
        for target in targets where !target.isCatchAll {
            let paths = expand(target).filter { !FileSystem.isProtected($0) }
            map[target.id] = paths
            claimed.append(contentsOf: paths)
        }
        // Los "cajon de sastre" descartan lo que ya cubre otra fila, incluido
        // lo que se haya quedado un cajon de sastre anterior.
        for target in targets where target.isCatchAll {
            let paths = expand(target).filter { path in
                guard !FileSystem.isProtected(path) else { return false }
                return !claimed.contains {
                    path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
                }
            }
            map[target.id] = paths
            claimed.append(contentsOf: paths)
        }
        return map
    }

    /// Como se titula un trozo del desglose. `nil` deja el nombre de la carpeta,
    /// que es lo que sirve para versiones, proyectos de Xcode y apps.
    nonisolated static func label(for path: String, naming: Naming) -> String? {
        switch naming {
        case .folder:
            return nil
        case .simulator:
            return FileSystem.simulatorName(of: path)
        case .project:
            // `Projects/HaumeaImages/composeApp/build`. Sin el sitio, diez
            // carpetas llamadas build son la misma fila diez veces.
            let pretty = FileSystem.prettyPath(path)
            return pretty.hasPrefix("~/") ? String(pretty.dropFirst(2)) : pretty
        }
    }

    // MARK: - Limpieza

    /// Las filas que se van a limpiar, en el orden en que se limpian.
    ///
    /// La Papelera va la primera. Detras, vaciaria tambien lo que el resto de
    /// filas acaba de mover a ella, que es justo lo que el usuario queria
    /// poder recuperar.
    nonisolated static func plan(_ rows: [Row]) -> [Row] {
        let chosen = rows.filter { $0.anySelected && !$0.isEmpty }
        return chosen.filter(\.target.isTrash) + chosen.filter { !$0.target.isTrash }
    }

    func clean() {
        guard !isScanning && !isCleaning else { return }
        let plan = Engine.plan(visibleRows)
        guard !plan.isEmpty else { return }

        isCleaning = true
        progress = 0
        // Sin esto la alerta del informe sale en cuanto empieza la limpieza,
        // con las cifras de la anterior.
        lastReport = nil
        refreshVolume()
        let freeBefore = volume?.free
        let trash = useTrash
        let scannedAt = self.scannedAt
        let log = OperationLog.shared
        log.begin(rows: plan.count, toTrash: trash)

        work = Task { [weak self] in
            guard let self else { return }
            var freed: Int64 = 0
            var cleaned = 0
            var failures: [String] = []
            var skipped: [String] = []

            for (index, row) in plan.enumerated() {
                if Task.isCancelled { break }
                self.mark(row.id, .cleaning)
                self.currentStep = row.target.name

                let (paths, scope) = row.victims
                let target = row.target
                let records = row.records
                // Las carpetas de codigo del usuario se leen aqui, fuera de la
                // tarea de fondo: lo que se borra no depende de lo que cambie
                // mientras tanto en las preferencias. Solo los barridos las usan.
                let codeRoots = target.isSweep ? CodeRoots.load() : []
                // Vaciar la Papelera moviendo su contenido a la Papelera no
                // libera nada.
                let toTrash = trash && !target.isTrash
                // Quien esta abierto se mira ahora, no al analizar: entre una
                // cosa y otra el usuario ha podido abrir Xcode.
                let apps = ProcessSnapshot.runningApps()
                let stop = OSAllocatedUnfairLock(initialState: false)
                let job = Task.detached(priority: .userInitiated) {
                    // `leftover` es siempre "lo que sigue ahi despues", asi
                    // que las dos ramas se miden igual mas abajo.
                    let stopped: @Sendable () -> Bool = { stop.withLock { $0 } }
                    if let reclaim = target.reclaim {
                        // Lo que borra otra herramienta lo vigila ella: simctl
                        // no borra un simulador arrancado, y docker prune
                        // necesita Docker abierto para funcionar.
                        return Engine.reclaim(reclaim, paths: paths, records: records,
                                              isCancelled: stopped)
                    }
                    let snapshot = ProcessSnapshot.capture(apps: apps)
                    let check = Engine.preflight(paths, target: target, records: records,
                                                 scannedAt: scannedAt, snapshot: snapshot,
                                                 codeRoots: codeRoots)
                    var result = Engine.erase(paths: check.allowed, scope: scope, toTrash: toTrash,
                                              codeRoots: codeRoots, isCancelled: stopped)
                    for (path, reason) in check.skipped {
                        result.skipped[path] = reason
                        result.leftover[path] = records[path]?.bytes ?? FileSystem.usage(of: path).bytes
                    }
                    return result
                }
                // Una tarea suelta no hereda la cancelacion de la de fuera. Sin
                // avisarla, «Detener» esperaba a que acabase la fila entera, y
                // un `docker system prune` puede llevar minutos.
                let result = await withTaskCancellationHandler {
                    await job.value
                } onCancel: {
                    stop.withLock { $0 = true }
                }

                let recovered = max(0, row.selectedBytes - result.failedBytes)
                let allSkipped = !result.skipped.isEmpty && result.skipped.count == paths.count
                if !result.errors.isEmpty {
                    self.mark(row.id, .failed(result.errors[0]))
                    failures.append("\(target.name): \(result.errors[0])")
                } else if allSkipped {
                    self.mark(row.id, .skipped(Engine.reasons(result.skipped)))
                } else {
                    self.mark(row.id, .cleaned(recovered))
                }
                if !result.skipped.isEmpty {
                    skipped.append("\(target.name) (\(Engine.reasons(result.skipped)))")
                }
                Engine.log(result, paths: paths, records: records, target: target,
                           toTrash: toTrash, into: log)
                freed += recovered
                if recovered > 0 { cleaned += 1 }
                self.settle(row.id, leftover: result.leftover)
                self.progress = Double(index + 1) / Double(plan.count)
            }

            log.end(freed: freed)
            self.lastReport = Report(freed: freed, cleaned: cleaned, failures: failures,
                                     toTrash: trash, skipped: skipped, freeBefore: freeBefore)
            self.isCleaning = false
            self.currentStep = ""
            self.refreshVolume()
            self.settleVolume()
            self.refreshOccupancy()
        }
    }

    /// Los motivos distintos, en una linea: «en uso por Xcode; ha cambiado».
    nonisolated private static func reasons(_ skipped: [String: String]) -> String {
        var seen: [String] = []
        for reason in skipped.values.sorted() where !seen.contains(reason) { seen.append(reason) }
        return seen.joined(separator: "; ")
    }

    /// Una linea por ruta en el historial. Lo liberado es lo que ocupaba al
    /// analizar menos lo que sigue ahi: no se vuelve a medir antes de borrar.
    nonisolated private static func log(_ result: EraseResult, paths: [String],
                                        records: [String: Row.Record], target: Target,
                                        toTrash: Bool, into log: OperationLog) {
        let action: OperationLog.Action = target.reclaim != nil ? .tool : (toTrash ? .trash : .delete)
        let name = target.name
        for path in paths {
            let before = records[path]?.bytes ?? 0
            let left = result.leftover[path] ?? 0
            if let reason = result.skipped[path] {
                log.record(action, .skipped, bytes: 0, path: path, detail: "\(name): \(reason)")
                continue
            }
            let status: OperationLog.Status = left == 0 ? .ok : (left < before ? .partial : .failed)
            log.record(action, status, bytes: max(0, before - left), path: path, detail: name)
        }
    }

    private func mark(_ id: String, _ state: RowState) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = state
    }

    private func settle(_ id: String, leftover: [String: Int64]) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].settle(leftover: leftover)
    }

    // MARK: - Comprobacion previa

    struct Preflight: Sendable {
        var allowed: [String] = []
        /// Ruta -> motivo. No se tocan.
        var skipped: [String: String] = [:]
    }

    /// Lo ultimo que se mira antes de borrar, ruta a ruta.
    ///
    /// - Que ningun programa abierto la este usando. Si no se puede saber,
    ///   tampoco se borra.
    /// - Que sea el mismo objeto que se midio: una carpeta recreada, o
    ///   sustituida por un enlace, ya no es lo que el usuario aprobo.
    /// - En los artefactos de proyecto, ademas, que nadie haya escrito dentro
    ///   desde que empezo el analisis y que no se haya versionado en git.
    ///
    /// `codeRoots` son las carpetas de codigo del usuario: solo importan para
    /// saber en que repositorios mirar lo versionado.
    nonisolated static func preflight(_ paths: [String], target: Target,
                                      records: [String: Row.Record], scannedAt: Date?,
                                      snapshot: ProcessSnapshot,
                                      codeRoots: [String] = [],
                                      owners: [Owner] = Owners.all) -> Preflight {
        var check = Preflight()
        for path in paths {
            // Ya no esta: no hay nada que comprobar, ni que borrar.
            guard FileSystem.exists(path) else {
                check.allowed.append(path)
                continue
            }
            switch snapshot.occupancy(of: path, owners: owners) {
            case .busy(let name):
                check.skipped[path] = L("skip.busy", name)
                continue
            case .unknown:
                check.skipped[path] = L("skip.unknown")
                continue
            case .free:
                break
            }
            if let recorded = records[path]?.identity, FileSystem.identity(of: path) != recorded {
                check.skipped[path] = L("skip.changed")
                continue
            }
            if target.isSweep, let scannedAt, FileSystem.modified(path, since: scannedAt) {
                check.skipped[path] = L("skip.changed")
                continue
            }
            check.allowed.append(path)
        }

        if target.isSweep && !check.allowed.isEmpty {
            let roots = target.searchRoots(userRoots: codeRoots)
            for path in Tools.versioned(check.allowed, within: roots) {
                check.skipped[path] = L("skip.changed")
            }
            check.allowed.removeAll { check.skipped[$0] != nil }
        }
        return check
    }

    // MARK: - Borrado real (fuera del hilo principal)

    struct EraseResult: Sendable {
        var removed = 0
        /// Lo que sigue ocupando cada ruta que se intento borrar. Es por ruta y
        /// no un total para saber que subcarpetas se quedan en la lista.
        var leftover: [String: Int64] = [:]
        var errors: [String] = []
        /// Ruta -> motivo de lo que no se toco a proposito.
        var skipped: [String: String] = [:]

        var failedBytes: Int64 { leftover.values.reduce(0, +) }
    }

    nonisolated static func erase(paths: [String], scope: Scope, toTrash: Bool,
                                  codeRoots: [String] = [],
                                  isCancelled: () -> Bool = { false }) -> EraseResult {
        var result = EraseResult()

        for path in paths {
            // Ya no esta: alguien se ha adelantado. No es un error, y no queda nada.
            guard FileSystem.exists(path) else {
                result.leftover[path] = 0
                continue
            }
            guard mayDelete(path, codeRoots: codeRoots) else {
                result.errors.append("ruta protegida: \(FileSystem.prettyPath(path))")
                continue
            }

            let victims: [String] = (scope == .contents && FileSystem.isDirectory(path))
                ? FileSystem.children(of: path)
                : [path]

            var left: Int64 = 0
            for victim in victims {
                guard mayDelete(victim, codeRoots: codeRoots) else { continue }
                // Detenido: lo que queda no se toca, pero se mide. Sin eso la
                // fila daria por liberado lo que sigue en el disco.
                if isCancelled() {
                    left += FileSystem.usage(of: victim).bytes
                    continue
                }
                do {
                    try FileSystem.remove(victim, toTrash: toTrash)
                    result.removed += 1
                } catch {
                    // Solo medimos lo que NO se ha podido borrar. En el caso normal
                    // (todo se borra) nos ahorramos recorrer el arbol una segunda vez.
                    left += FileSystem.usage(of: victim).bytes
                    let reason = (error as NSError).localizedFailureReason
                        ?? error.localizedDescription
                    if result.errors.count < 5 { result.errors.append(reason) }
                }
            }
            result.leftover[path] = left
        }
        return result
    }

    // MARK: - Recuperar via herramienta

    /// Igual que `erase`, pero pidiendoselo a quien creo la ruta.
    ///
    /// Devuelve el mismo `EraseResult` a proposito: `leftover` es lo que
    /// sigue ocupando disco al terminar, medido de nuevo, no lo que la
    /// herramienta diga haber liberado. Es la unica cifra que se puede
    /// prometer, porque aqui no borramos nosotros.
    ///
    /// `records` es lo que se ofrecio al analizar. Solo lo necesita Docker,
    /// cuya cifra no es lo que pesa la ruta (ver `DockerPrune`).
    ///
    /// La Papelera no pinta nada: ni `simctl` ni `docker` saben moverse a ella.
    nonisolated static func reclaim(
        _ kind: Reclaim,
        paths: [String],
        records: [String: Row.Record] = [:],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> EraseResult {
        var result = EraseResult()

        func measure(_ list: [String]) {
            for path in list { result.leftover[path] = FileSystem.usage(of: path).bytes }
        }

        func note(_ text: String) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, result.errors.count < 5 else { return }
            result.errors.append(clean)
        }

        switch kind {

        case .simulator:
            for path in paths {
                guard mayDelete(path) else {
                    note("ruta protegida: \(FileSystem.prettyPath(path))")
                    continue
                }
                // Detenido: no se lanza ninguno mas, pero los que quedan se
                // miden igual para que la cuenta no los de por borrados.
                if !isCancelled() {
                    // La carpeta se llama como el UDID, que es justo lo que
                    // simctl espera. Un simulador arrancado se niega a borrarse,
                    // y el mensaje de simctl lo explica mejor que nosotros.
                    let udid = (path as NSString).lastPathComponent
                    let run = Tools.run("/usr/bin/xcrun", ["simctl", "delete", udid])
                    if run.ok {
                        result.removed += 1
                    } else {
                        note(run.firstLine)
                    }
                }
                measure([path])
            }

        case .docker:
            // Lo que se ofrecio: lo que Docker dijo al analizar que se llevaria.
            // Lo que quede se apunta en la primera ruta, igual que se midio.
            let promised = paths.reduce(Int64(0)) { $0 + (records[$1]?.bytes ?? 0) }
            func remain(_ bytes: Int64) {
                for (index, path) in paths.enumerated() {
                    result.leftover[path] = index == 0 ? max(0, bytes) : 0
                }
            }
            guard let docker = Tools.locate("docker") else {
                note(L("error.tool.missing", "docker"))
                remain(promised)
                return result
            }
            let disk = { paths.reduce(Int64(0)) { $0 + FileSystem.usage(of: $1).bytes } }
            let diskBefore = disk()
            var pruned = false
            // Ni `--all` ni `--volumes`. Sin `--all` solo caen las imagenes
            // colgantes, la cache de construccion y los contenedores parados:
            // una imagen etiquetada que no tenga contenedor corriendo cuenta
            // como "sin usar" para Docker, y suele ser justo la que alguien
            // construyo para subirla a un servidor. En los volumenes viven
            // bases de datos. Ninguna de las dos cosas es cache.
            if !isCancelled() {
                let run = Tools.run(docker, ["system", "prune", "--force"],
                                    isCancelled: isCancelled)
                if run.ok {
                    result.removed += 1
                    pruned = true
                } else if !isCancelled() {
                    // Si lo hemos parado nosotros, lo que diga al morir no es
                    // un error que ensenar.
                    note(run.firstLine)
                }
            }
            // Dos medidas, y vale la peor: lo que Docker aun se llevaria y lo
            // que el Mac aun no ha recuperado. Docker puede haber borrado algo
            // que `Docker.raw` todavia no ha devuelto, y eso no es hueco libre.
            let remaining = DockerPrune.prunable() ?? 0
            let shrunk = DockerPrune.shrink(from: diskBefore,
                                            expecting: pruned ? promised - remaining : 0,
                                            isCancelled: isCancelled,
                                            measure: disk)
            remain(max(remaining, promised - shrunk))

        case .runtime:
            // Se vuelve a preguntar ahora: lo que se aprobo era un runtime sin
            // simuladores, y desde el analisis alguien ha podido crear uno.
            // Por eso no se borra por la ruta que se enseno, sino por el
            // identificador que simctl da hoy a esa ruta, si sigue huerfano.
            guard let orphans = SimRuntimes.orphans() else {
                note(L("error.tool.missing", "xcrun simctl"))
                for path in paths { result.leftover[path] = SimRuntimes.cached(at: path)?.bytes ?? 0 }
                return result
            }
            for path in paths {
                guard let runtime = orphans.first(where: { $0.bundlePath == path }) else {
                    // O ya no esta, o ya no es huerfano. Lo segundo se nota
                    // porque sigue montado.
                    if FileSystem.exists(path) {
                        result.skipped[path] = L("skip.changed")
                        result.leftover[path] = SimRuntimes.cached(at: path)?.bytes ?? 0
                    } else {
                        result.leftover[path] = 0
                    }
                    continue
                }
                if isCancelled() {
                    result.leftover[path] = runtime.bytes
                    continue
                }
                let run = SimRuntimes.delete(runtime.identifier)
                if run.ok {
                    result.removed += 1
                    result.leftover[path] = 0
                } else {
                    note(run.firstLine)
                    result.leftover[path] = runtime.bytes
                }
            }
        }

        return result
    }

    // MARK: - Red de seguridad

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
    ///
    /// La unica excepcion fuera del home es la de `isInCodeRoot`: un artefacto
    /// de proyecto dentro de una carpeta de codigo que el usuario eligio a mano.
    /// Es estrecha a proposito: solo lo ofrece el barrido, solo por nombre de
    /// artefacto, solo dentro de esa carpeta y solo si sigue siendo valida en
    /// el momento de borrar. Nunca la raiz de un volumen ni nada del sistema.
    ///
    /// Solo rutas absolutas, y sin caracteres de control: un salto de linea
    /// en una ruta no lo pone ninguna herramienta, lo pone un error.
    nonisolated static func isSafe(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return false }
        let home = NSHomeDirectory()
        let normalized = (path as NSString).standardizingPath
        guard normalized.hasPrefix(home + "/") else { return false }
        let relative = String(normalized.dropFirst(home.count + 1))
        guard !relative.isEmpty else { return false }
        let components = (relative as NSString).pathComponents
        if components.contains("..") { return false }
        if components.count == 1 { return !untouchableTopLevel.contains(components[0]) }
        return true
    }

    /// La comprobacion completa antes de borrar una ruta.
    ///
    /// `isSafe` y `isProtected` miran la ruta tal y como esta escrita. Si una
    /// de las carpetas de por medio es un enlace, lo que se borra de verdad
    /// esta en otro sitio: un `~/.npm` que apunte a `~/Documents/npm` haria
    /// que vaciar la cache de npm borrase dentro de Documentos. Asi que se
    /// resuelve la ruta y se vuelve a mirar.
    ///
    /// Lo resuelto solo puede quitar permiso, nunca darlo. Se acepta que caiga
    /// en otro disco —quien tiene `~/.gradle` en un disco externo quiere
    /// poder limpiarlo—, pero no en el sistema, ni en otra carpeta protegida
    /// del home.
    ///
    /// Fuera del home, lo unico que pasa es `isInCodeRoot`, con las carpetas
    /// de codigo del usuario (`codeRoots`, vacio fuera de los barridos). Ahi
    /// tambien se exige el marcador del barrido, no solo el nombre.
    nonisolated static func mayDelete(_ path: String, codeRoots: [String] = []) -> Bool {
        guard isSafe(path) else { return isInCodeRoot(path, roots: codeRoots) }
        guard !FileSystem.isProtected(path) else { return false }
        guard FileSystem.exists(path) else { return true }
        guard let real = FileSystem.canonical(path) else { return false }
        if real == (path as NSString).standardizingPath { return true }
        if isSafe(real) && !FileSystem.isProtected(real) { return true }
        return isOnExternalVolume(real)
    }

    /// Si `path` es un artefacto dentro de una de las carpetas de codigo del
    /// usuario. Las raices se validan otra vez aqui, con el disco tal como
    /// esta ahora: si el disco se ha desmontado o la carpeta es ya otra cosa,
    /// no sirven.
    ///
    /// Defensa en profundidad: si la ruta existe, se vuelve a exigir el
    /// marcador que el barrido pide para su nombre (una `Library` sin
    /// `ProjectSettings/ProjectVersion.txt` al lado no es de Unity). Si no
    /// existe no hay nada que borrar, y eso ya lo contesta la capa de arriba.
    nonisolated static func isInCodeRoot(_ path: String, roots: [String]) -> Bool {
        let canonicalRoots = roots.compactMap { root -> String? in
            guard CodeRoots.check(root) == nil else { return nil }
            return CodeRoots.canonicalPath(root)
        }
        guard !canonicalRoots.isEmpty, path.hasPrefix("/") else { return false }
        if FileSystem.exists(path), !FileSystem.hasArtifactMarker(path) { return false }
        // Si la ruta no existe, basta la escrita: lo mismo que hace `mayDelete`
        // con lo que ya no esta.
        let real: String
        if FileSystem.exists(path) {
            guard let resolved = FileSystem.canonical(path) else { return false }
            real = resolved
        } else {
            real = (path as NSString).standardizingPath
        }
        return isInCodeRoot(path, real: real, canonicalRoots: canonicalRoots)
    }

    /// La parte sin disco de `isInCodeRoot`. `path` es la ruta tal como se
    /// escribio, `real` la que lleva de verdad y `canonicalRoots` las raices ya
    /// resueltas. Se exige que la escrita y la real caigan dentro de la misma
    /// raiz, para que un enlace no saque el borrado de ella.
    nonisolated static func isInCodeRoot(_ path: String, real: String,
                                         canonicalRoots: [String]) -> Bool {
        guard path.hasPrefix("/"), real.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !(path as NSString).pathComponents.contains("..")
        else { return false }
        let written = (path as NSString).standardizingPath
        guard FileSystem.matchesArtifact((written as NSString).lastPathComponent,
                                         Catalog.projectArtifacts),
              !FileSystem.isProtected(written), !FileSystem.isProtected(real)
        else { return false }
        // Estrictamente dentro: la propia raiz no es un artefacto que borrar.
        return canonicalRoots.contains { root in
            written.hasPrefix(root + "/") && real.hasPrefix(root + "/")
        }
    }

    /// Dentro de un disco montado en /Volumes, nunca su raiz.
    nonisolated static func isOnExternalVolume(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        return components.count >= 4
            && components[0] == "/" && components[1] == "Volumes"
            && !components.contains("..")
    }
}
