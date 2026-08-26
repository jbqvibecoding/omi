import SwiftUI
import AppKit

/// Browse, read, correct and roll back what omi remembers about people and projects.
///
/// Memory you cannot inspect is memory you cannot trust, so this shows the actual file
/// content — not a summary of it — and every save is reversible from the version list.
struct DossierBrowserView: View {
    @ObservedObject private var store = DossierStore.shared
    @State private var kind: DossierKind = .person
    @State private var selectedSlug: String?
    @State private var editorText = ""
    @State private var query = ""
    @State private var isCurating = false
    @State private var status = ""
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What omi remembers").scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                Button("Reveal in Finder") {
                    DossierStore.shared.ensureDirectories()
                    NSWorkspace.shared.activateFileViewerSelecting([DossierStore.shared.root])
                }
                .buttonStyle(.plain).scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
            }

            Text("One markdown file per person, organization, project and topic — written from your meetings, editable by you.")
                .scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)

            Picker("", selection: $kind) {
                ForEach(DossierKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in selectedSlug = nil }

            TextField("Search", text: $query).textFieldStyle(.roundedBorder)

            HStack(alignment: .top, spacing: 12) {
                list
                detail
            }

            if !status.isEmpty {
                Text(status).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }

            HStack {
                Button(isCurating ? "Tidying…" : "Tidy up now") {
                    Task {
                        isCurating = true
                        let result = await DossierGardener.run()
                        isCurating = false
                        status =
                            "Curated \(result["curated"] ?? "0"), kept originals for \(result["rejected"] ?? "0"), marked \(result["archived"] ?? "0") stale."
                    }
                }
                .disabled(isCurating)
                Spacer()
                Button("Done") { onDismiss() }
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear { DossierStore.shared.ensureDirectories() }
    }

    // MARK: - Pieces

    private var entries: [Dossier] {
        let all = DossierStore.shared.all().filter { $0.kind == kind }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all.sorted { $0.name < $1.name } }
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.body.lowercased().contains(needle)
        }.sorted { $0.name < $1.name }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    Text("Nothing here yet — omi writes these after your meetings.")
                        .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                }
                ForEach(entries) { dossier in
                    Button {
                        selectedSlug = dossier.slug
                        editorText = dossier.markdown
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dossier.name).scaledFont(size: 13)
                                    .foregroundColor(OmiColors.textPrimary)
                                Text(subtitle(dossier)).scaledFont(size: 10)
                                    .foregroundColor(OmiColors.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(
                            selectedSlug == dossier.slug
                                ? OmiColors.backgroundTertiary : Color.clear
                        )
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 230)
    }

    @ViewBuilder
    private var detail: some View {
        if let slug = selectedSlug,
            let dossier = DossierStore.shared.load(kind: kind, slug: slug)
        {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $editorText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(OmiColors.backgroundTertiary.opacity(0.5))
                    .cornerRadius(6)

                HStack {
                    Button("Save") {
                        guard let edited = DossierStore.parse(editorText, kind: kind, slug: slug)
                        else { return }
                        DossierStore.shared.save(edited)
                        DossierIndex.shared.invalidate()
                        status = "Saved \(dossier.name)."
                    }
                    Button("Delete") {
                        DossierStore.shared.delete(kind: kind, slug: slug)
                        DossierIndex.shared.invalidate()
                        selectedSlug = nil
                        status = "Deleted \(dossier.name)."
                    }
                    .foregroundColor(OmiColors.error)
                    Spacer()
                }

                let history = DossierStore.shared.snapshots(kind: kind, slug: slug)
                if !history.isEmpty {
                    Text("Earlier versions").scaledFont(size: 11)
                        .foregroundColor(OmiColors.textSecondary)
                    ForEach(history.prefix(5)) { snapshot in
                        HStack {
                            Text(snapshot.stamp).scaledFont(size: 10)
                                .foregroundColor(OmiColors.textTertiary)
                            Spacer()
                            Button("Restore") {
                                DossierStore.shared.restore(
                                    kind: kind, slug: slug, snapshot: snapshot.url)
                                DossierIndex.shared.invalidate()
                                editorText =
                                    DossierStore.shared.load(kind: kind, slug: slug)?.markdown
                                    ?? editorText
                                status = "Restored the version from \(snapshot.stamp)."
                            }
                            .buttonStyle(.plain).scaledFont(size: 10)
                            .foregroundColor(OmiColors.textSecondary)
                        }
                    }
                }
            }
        } else {
            VStack {
                Text("Pick a file to read or correct it.")
                    .scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subtitle(_ dossier: Dossier) -> String {
        var parts = ["\(dossier.lineCount) lines"]
        if let updated = dossier.field("updated") { parts.append(updated) }
        if dossier.isArchived { parts.append("quiet") }
        if !dossier.openItems.isEmpty { parts.append("\(dossier.openItems.count) open") }
        return parts.joined(separator: " · ")
    }
}
