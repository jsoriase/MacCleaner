import SwiftUI

/// Lo que ensena el panel principal: todo junto, como antes, o una sola
/// categoria.
enum SidebarItem: Hashable {
    case all
    case category(Category)

    var category: Category? {
        if case .category(let group) = self { return group }
        return nil
    }
}

struct Sidebar: View {
    @ObservedObject var engine: Engine
    @Binding var scope: SidebarItem

    var body: some View {
        // La lista admite quedarse sin seleccion (Cmd+clic); el panel
        // principal siempre tiene que ensenar algo, asi que eso se ignora.
        List(selection: Binding<SidebarItem?>(get: { scope }, set: { if let new = $0 { scope = new } })) {
            SidebarRow(title: L("sidebar.all"),
                       symbol: "square.grid.2x2",
                       bytes: engine.foundBytes,
                       scanned: engine.hasScanned,
                       busy: false,
                       marked: engine.anySelected)
                .tag(SidebarItem.all)

            Section(L("sidebar.categories")) {
                ForEach(Category.allCases) { group in
                    SidebarRow(title: group.title,
                               symbol: group.symbol,
                               bytes: engine.groupBytes(group),
                               scanned: engine.hasScanned,
                               busy: engine.isBusy(group),
                               marked: engine.anySelected(in: group))
                        .tag(SidebarItem.category(group))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let bytes: Int64
    let scanned: Bool
    let busy: Bool
    /// Hay algo marcado aqui. El boton de limpiar actua sobre todas las
    /// categorias a la vez, no solo sobre la que se esta viendo.
    let marked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                // Analizada y sin nada: sigue en la lista, para que no salte,
                // pero sin llamar la atencion.
                .foregroundStyle(scanned && bytes == 0 ? .secondary : .primary)

            Spacer(minLength: 4)

            if marked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if busy {
                ProgressView().controlSize(.mini)
            } else if bytes > 0 {
                // Mientras dura el primer analisis las cifras van apareciendo.
                Text(FileSystem.humanBytes(bytes))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
