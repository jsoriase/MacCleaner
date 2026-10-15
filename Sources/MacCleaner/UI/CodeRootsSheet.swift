import SwiftUI
import AppKit

/// Hoja para elegir las carpetas de codigo propias. Ademas de las que vienen
/// de fabrica, dentro del home, el usuario puede anadir las suyas, tambien en
/// discos externos. Ver `CodeRoots`.
struct CodeRootsSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    /// El motivo del ultimo rechazo, para la alerta. nil si no hay ninguno.
    @State private var rejection: CodeRoots.Rejection?

    /// Solo lo que existe aqui: `expand` ya descarta lo que falta.
    private var defaults: [String] {
        Catalog.codeRoots.flatMap { FileSystem.expand($0) }
    }

    /// Mientras se analiza o se limpia la lista no se toca.
    private var busy: Bool {
        engine.isScanning || engine.isCleaning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("coderoots.title"))
                    .font(.title3.weight(.semibold))
                Text(L("coderoots.note"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("coderoots.defaults"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(defaults, id: \.self) { path in
                    Text(FileSystem.prettyPath(path))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("coderoots.custom"))
                    .font(.system(size: 12, weight: .semibold))
                if engine.userCodeRoots.isEmpty {
                    Text(L("coderoots.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(engine.userCodeRoots, id: \.self) { path in
                    customRow(path)
                }
            }

            HStack {
                Button(L("coderoots.add"), action: chooseFolders)
                    .disabled(busy)
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(L("coderoots.rescan"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .alert(L("coderoots.reject.title"), isPresented: Binding(
            get: { rejection != nil },
            set: { if !$0 { rejection = nil } }
        )) {
            Button(L("common.done")) { rejection = nil }
        } message: {
            Text(rejection?.message ?? "")
        }
    }

    /// Una carpeta del usuario. Si ahora mismo no se puede usar (disco
    /// desmontado, carpeta borrada) lo dice, pero sigue en la lista.
    private func customRow(_ path: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FileSystem.prettyPath(path))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if CodeRoots.check(path) != nil {
                    Text(L("coderoots.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(L("coderoots.remove")) { engine.removeCodeRoot(path) }
                .disabled(busy)
        }
    }

    /// El selector de carpetas del sistema. Solo directorios, varios a la vez.
    /// Si alguna no sirve, se muestra el motivo de la primera.
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("coderoots.panel.prompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let refused = engine.addCodeRoot(url.path), rejection == nil {
                rejection = refused
            }
        }
    }
}
