import AppKit
import SwiftUI

struct CommitSheet: View {
    @ObservedObject var store: SvnDockStore

    @State private var message = ""
    @State private var includedEntryIDs: Set<SvnDockStatusEntry.ID>

    init(store: SvnDockStore) {
        self.store = store
        let committableIDs = Set(store.committableEntries.map(\.id))
        let selectedCommittableIDs = store.selectedEntryIDs.intersection(committableIDs)
        _includedEntryIDs = State(
            initialValue: selectedCommittableIDs.isEmpty
                ? committableIDs
                : selectedCommittableIDs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("提交到 SVN")
                        .font(.headline)
                    Text(store.selectedWorkingCopy?.name ?? "未选择工作副本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("提交说明")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .frame(height: 96)
            }
            .padding(16)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text("待提交文件")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(includedEntryIDs.count == store.committableEntries.count ? "全部取消" : "全部选择") {
                        if includedEntryIDs.count == store.committableEntries.count {
                            includedEntryIDs.removeAll()
                        } else {
                            includedEntryIDs = Set(store.committableEntries.map(\.id))
                        }
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .frame(height: 38)

                List(store.committableEntries) { entry in
                    Toggle(isOn: inclusionBinding(for: entry)) {
                        HStack(spacing: 8) {
                            Image(systemName: entry.status.symbolName)
                                .foregroundStyle(entry.status.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                Text(entry.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                if store.entries.contains(where: { $0.status == .conflicted }) {
                    Label("冲突文件已自动排除", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("将提交 \(includedEntryIDs.count) 个文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    store.cancelCommit()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(store.isBusy)

                Button("提交") {
                    store.commit(message: message, entryIDs: includedEntryIDs)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    store.isBusy
                    || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || includedEntryIDs.isEmpty
                )
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 560)
        .interactiveDismissDisabled(store.isBusy)
    }

    private func inclusionBinding(for entry: SvnDockStatusEntry) -> Binding<Bool> {
        Binding(
            get: { includedEntryIDs.contains(entry.id) },
            set: { isIncluded in
                if isIncluded {
                    includedEntryIDs.insert(entry.id)
                } else {
                    includedEntryIDs.remove(entry.id)
                }
            }
        )
    }
}
