import SwiftUI
import AppKit

// MARK: - Finder

/// Abre Finder con las rutas ya seleccionadas. Se filtran las que ya no existen:
/// revelar una ruta borrada abre una ventana vacia sin explicar por que.
func revealInFinder(_ paths: [String]) {
    let urls = paths
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

/// Abre el historial de limpiezas con la app que el sistema tenga para los
/// `.log`, que normalmente es Consola.
func openHistory() {
    let log = OperationLog.shared
    guard log.exists else { return }
    NSWorkspace.shared.open(log.url)
}

// MARK: - Cabecera de categoria

struct GroupHeader: View {
    let group: Category
    let bytes: Int64
    let showBytes: Bool
    let onAll: () -> Void
    let onNone: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))

            if showBytes && bytes > 0 {
                Text(FileSystem.humanBytes(bytes))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Spacer()

            if hovering {
                Button(L("group.all"), action: onAll).buttonStyle(.link)
                Button(L("group.none"), action: onNone).buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Fila

/// Casilla de tres estados: hace falta porque una fila desplegable puede
/// tener solo algunas de sus subcarpetas marcadas.
struct TriStateCheckbox: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(state == .off ? Color.secondary.opacity(0.7) : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .off:   return "square"
        case .mixed: return "minus.square.fill"
        case .on:    return "checkmark.square.fill"
        }
    }
}

struct TargetRow: View {
    let row: Row
    var occupancy: Occupancy = .free
    let onToggle: () -> Void
    let onExpand: () -> Void
    var onIgnore: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if row.hasItems {
                Button(action: onExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.expanded ? 90 : 0))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }

            if row.hasItems {
                TriStateCheckbox(state: row.checkState, action: onToggle)
            } else {
                Toggle("", isOn: Binding(get: { row.selected }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.target.name)
                        .font(.system(size: 13))
                        .foregroundStyle(row.isEmpty ? .secondary : .primary)
                    RiskBadge(risk: row.target.risk, why: row.target.why)
                    BusyBadge(occupancy: occupancy)
                    if row.hasItems {
                        Text("\(row.items.count)")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.target.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(helpText)
        .contextMenu {
            // Antes de borrar algo marcado como "Cuidado", lo normal es querer
            // mirarlo primero.
            Button(L("row.reveal")) { revealInFinder(row.paths) }
                .disabled(row.paths.isEmpty)
            Divider()
            Button(L("row.ignore"), action: onIgnore)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .scanning, .cleaning:
            ProgressView().controlSize(.small)
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(reason)
        case .skipped(let reason):
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .help(reason)
        case .cleaned(let freed):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(FileSystem.humanBytes(freed))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .trailing, spacing: 0) {
                Text(FileSystem.humanBytes(row.usage.bytes))
                    .font(.system(size: 13, weight: row.isEmpty ? .regular : .medium, design: .rounded))
                    .foregroundStyle(row.isEmpty ? .secondary : .primary)
                if row.usage.files > 0 {
                    Text(L("row.files", row.usage.files))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 76, alignment: .trailing)
        }
    }

    private var helpText: String {
        if row.paths.isEmpty { return L("row.noPath") }
        return row.paths.map(FileSystem.prettyPath).joined(separator: "\n")
    }
}

/// Una subcarpeta dentro de una fila desplegable.
struct SubItemRow: View {
    let item: SubItem
    var occupancy: Occupancy = .free
    /// En un barrido de proyectos, lo escrito esta semana se senala: los
    /// botones de seleccion rapida lo dejan sin marcar.
    var flagsRecent = false
    let onToggle: (Bool) -> Void
    var onIgnore: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 24, height: 1)

            Toggle("", isOn: Binding(get: { item.selected }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()

            // El monoespaciado ayuda a comparar versiones y rutas; un nombre
            // de simulador no es ninguna de las dos cosas.
            Text(item.title)
                .font(.system(size: 12, design: item.label == nil ? .monospaced : .default))
                .foregroundStyle(item.usage.bytes == 0 ? .secondary : .primary)

            // Lo que de verdad decide si esta version sobra no es su tamano,
            // sino cuanto lleva sin tocarse.
            if let date = item.usage.modified {
                Text(FileSystem.humanAge(date))
                    .font(.system(size: 10))
                    .foregroundStyle(ageColor)
                    .lineLimit(1)
                    .help(recent ? L("row.recent.help") : FileSystem.humanDate(date))
            }

            BusyBadge(occupancy: occupancy)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 0) {
                Text(FileSystem.humanBytes(item.usage.bytes))
                    .font(.system(size: 12, design: .rounded))
                if item.usage.files > 0 {
                    Text(L("row.files", item.usage.files))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(helpText)
        .contextMenu {
            Button(L("row.reveal")) { revealInFinder([item.path]) }
            Divider()
            Button(L("row.ignore"), action: onIgnore)
        }
    }

    private var recent: Bool { flagsRecent && item.isRecent }

    private var ageColor: Color {
        if recent { return .blue }
        return item.isStale ? .orange : .secondary
    }

    private var helpText: String {
        var text = FileSystem.prettyPath(item.path)
        if let date = item.usage.modified {
            text += "\n" + FileSystem.humanDate(date)
        }
        return text
    }
}

// MARK: - En uso

/// «En uso: Xcode». Sin ella, la fila se marcaria, se confirmaria y se
/// saltaria al limpiar sin que nadie supiera por que.
struct BusyBadge: View {
    let occupancy: Occupancy

    var body: some View {
        switch occupancy {
        case .free:
            EmptyView()
        case .busy(let name):
            capsule(Text(L("row.busy", name)))
                .help(L("row.busy.help"))
        case .unknown:
            capsule(Image(systemName: "questionmark"))
                .help(L("row.busy.unknown"))
        }
    }

    private func capsule(_ content: some View) -> some View {
        content
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Riesgo

extension Risk {
    var color: Color {
        switch self {
        case .safe:    return .green
        case .rebuild: return .blue
        case .caution: return .orange
        }
    }
}

struct RiskBadge: View {
    let risk: Risk
    /// Que pasa si borras esta fila en concreto. El distintivo dice cuanto
    /// cuidado hay que tener; el raton encima dice por que.
    let why: Consequence

    var body: some View {
        Text(risk.label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(risk.color.opacity(0.15), in: Capsule())
            .foregroundStyle(risk.color)
            .help(why.text)
    }
}

/// Marca o desmarca de golpe todas las filas de un nivel de riesgo.
struct RiskFilterButton: View {
    let risk: Risk
    let bytes: Int64
    let isOn: Bool
    let showBytes: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(risk.plural)
                    .font(.system(size: 11, weight: .medium))
                if showBytes {
                    Text(bytes > 0 ? FileSystem.humanBytes(bytes) : "0")
                        .font(.system(size: 11, design: .rounded))
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(risk.color)
            .background(risk.color.opacity(isOn ? 0.22 : (hovering ? 0.14 : 0.08)), in: Capsule())
            .overlay(
                Capsule().strokeBorder(risk.color.opacity(isOn ? 0.55 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(risk.help)
    }
}

// MARK: - Estado inicial

struct EmptyState: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(L("empty.title"))
                .font(.title3)
            Text(L("empty.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("empty.button"), action: onScan)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Una categoria sin nada que ofrecer: todo vacio, ignorado u oculto por
/// «Ocultar vacias».
struct CategoryEmptyState: View {
    let group: Category

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: group.symbol)
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(L("detail.empty"))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
