import SwiftUI

struct ContentView: View {
    @StateObject private var engine = Engine()
    @State private var confirming = false
    @State private var showingReport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listBody
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 540)
        .alert(L("alert.clean.title", FileSystem.humanBytes(engine.selectedBytes)),
               isPresented: $confirming) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(engine.useTrash ? L("alert.clean.trash") : L("alert.clean.delete"),
                   role: .destructive) {
                engine.clean()
                showingReport = true
            }
        } message: {
            Text(confirmationMessage)
        }
        .alert(L("alert.report.title"), isPresented: Binding(
            get: { showingReport && engine.lastReport != nil },
            set: { if !$0 { showingReport = false } }
        )) {
            Button(L("common.done")) { showingReport = false }
        } message: {
            if let report = engine.lastReport {
                Text(reportMessage(report))
            }
        }
    }

    /// Se evita a proposito meter el numero dentro de la frase: cada idioma
    /// tiene sus propias reglas de plural y aqui no hacen falta.
    private var confirmationMessage: String {
        var text = engine.useTrash ? L("alert.clean.body.trash") : L("alert.clean.body.delete")
        text += "\n" + L("alert.clean.count", engine.selectedCount)
        let risky = engine.rows.filter { $0.anySelected && !$0.isEmpty && $0.target.risk == .caution }
        if !risky.isEmpty {
            text += "\n\n" + L("alert.clean.risky",
                                risky.map(\.target.name).joined(separator: ", "))
        }
        return text
    }

    private func reportMessage(_ report: Engine.Report) -> String {
        var text = L("alert.report.freed", FileSystem.humanBytes(report.freed))
        text += "\n" + L("alert.report.count", report.cleaned)
        if !report.failures.isEmpty {
            text += "\n\n" + L("alert.report.failures", report.failures.count)
        }
        return text
    }

    // MARK: - Cabecera

    /// En cuanto hay una cifra que ensenar, la cabecera deja de decir "Sin analizar"
    /// y va sumando en vivo mientras el analisis avanza.
    private var showsTotal: Bool {
        engine.hasScanned || engine.foundBytes > 0
    }

    private var header: some View {
        VStack(spacing: 11) {
            headerTop
            quickSelect
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    /// Botones que marcan de golpe todas las filas de un nivel de riesgo.
    /// Son acumulativos: Seguras + Se regeneran deja las dos tandas marcadas.
    private var quickSelect: some View {
        HStack(spacing: 7) {
            Text(L("select.mark"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(Risk.allCases, id: \.self) { risk in
                RiskFilterButton(
                    risk: risk,
                    bytes: engine.bytes(for: risk),
                    isOn: engine.allSelected(for: risk),
                    showBytes: engine.hasScanned,
                    action: { engine.toggleRisk(risk) }
                )
            }

            Spacer()

            if engine.anySelected {
                Button(L("select.clear")) { engine.clearSelection() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private var headerTop: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsTotal ? L("header.reclaimable") : "MacCleaner")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(showsTotal ? FileSystem.humanBytes(engine.foundBytes) : L("header.notScanned"))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.default, value: engine.foundBytes)

                // Sin esto, "12 GB recuperables" no responde a la pregunta que
                // trae el usuario, que es si le llega el disco.
                if let volume = engine.volume {
                    Text(L("header.free",
                           FileSystem.humanBytes(volume.free),
                           FileSystem.humanBytes(volume.total)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: volume.free)
                }
            }

            Spacer()

            if engine.isScanning || engine.isCleaning {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(engine.currentStep.isEmpty ? L("header.working") : engine.currentStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: engine.progress)
                        .frame(width: 180)
                }
                Button(L("header.stop")) { engine.cancel() }
            } else {
                Button {
                    engine.scan()
                } label: {
                    Label(engine.hasScanned ? L("header.rescan") : L("header.scan"),
                          systemImage: "magnifyingglass")
                        .frame(minWidth: 100)
                }
                .keyboardShortcut("r")
                .controlSize(.large)
            }
        }
    }

    // MARK: - Lista

    private var listBody: some View {
        List {
            ForEach(Category.allCases) { group in
                let rows = engine.rows(in: group)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            TargetRow(
                                row: row,
                                onToggle: { engine.toggleRow(row.id) },
                                onExpand: { engine.toggleExpanded(row.id) }
                            )
                            if row.expanded {
                                ForEach(row.items) { item in
                                    SubItemRow(item: item) {
                                        engine.setItemSelected(row.id, item.path, $0)
                                    }
                                }
                            }
                        }
                    } header: {
                        GroupHeader(
                            group: group,
                            bytes: engine.groupBytes(group),
                            showBytes: engine.hasScanned,
                            onAll: { engine.selectAll(in: group, true) },
                            onNone: { engine.selectAll(in: group, false) }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if !engine.hasScanned && !engine.isScanning {
                EmptyState { engine.scan() }
            }
        }
    }

    // MARK: - Pie

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle(L("footer.trash"), isOn: $engine.useTrash)
                .toggleStyle(.checkbox)
                .onChange(of: engine.useTrash) { _ in engine.persistTrashPreference() }
                .help(L("footer.trash.help"))

            Toggle(L("footer.hideEmpty"), isOn: $engine.hideEmpty)
                .toggleStyle(.checkbox)

            Spacer()

            if engine.hasScanned {
                Text(L("footer.selected", engine.selectedCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                confirming = true
            } label: {
                Label(L("footer.clean", FileSystem.humanBytes(engine.selectedBytes)),
                      systemImage: engine.useTrash ? "trash" : "sparkles")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .keyboardShortcut(.return)
            .disabled(engine.selectedBytes == 0 || engine.isScanning || engine.isCleaning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
