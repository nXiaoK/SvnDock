import SwiftUI
import UniformTypeIdentifiers

struct CheckoutSheet: View {
    @ObservedObject var store: SvnDockStore
    @State private var repositoryAddress = ""
    @State private var localPath = ""
    @State private var isChoosingParent = false
    @State private var pathSelectionError: String?
    @FocusState private var focusesAddress: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("从 SVN 仓库检出").font(.title2.bold())
            Text("将仓库中的项目下载到本地，完成后自动加入工作副本列表。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("SVN 仓库地址").font(.headline)
                TextField("https://svn.example.com/project/trunk", text: $repositoryAddress)
                    .textFieldStyle(.roundedBorder).focused($focusesAddress)
                    .accessibilityIdentifier("checkout.repositoryURL")
                Text("沿用本机 SVN 的认证与证书配置，不在应用中保存密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(store.isCheckingOut)
            VStack(alignment: .leading, spacing: 8) {
                Text("本地路径").font(.headline)
                HStack {
                    TextField("/Users/你的用户名/Projects/项目目录", text: $localPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("checkout.destinationPath")
                    Button("选择父目录…") { isChoosingParent = true }
                }
                Text("支持新目录或已有的空目录；不会覆盖已有文件。检出最新版本，不自动展开 svn:externals。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(store.isCheckingOut)
            if store.isCheckingOut {
                SvnDockTransferProgressView(model: store.transferProgress, requiredKind: .checkingOut)
            }
            if let error = pathSelectionError ?? store.checkoutError {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            }
            HStack {
                Spacer()
                if store.isCheckingOut {
                    Button(store.isCancellingCheckout ? "正在取消…" : "取消检出") { store.cancelCheckout() }
                        .disabled(store.isCancellingCheckout)
                } else {
                    Button("取消") { store.dismissCheckout() }.keyboardShortcut(.cancelAction)
                    Button("检出") {
                        pathSelectionError = nil
                        store.beginCheckout(repositoryAddress: repositoryAddress, localPath: localPath)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repositoryAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || localPath.isEmpty || isChoosingParent)
                }
            }
        }
        .padding(24).frame(width: 580)
        .interactiveDismissDisabled(store.isCheckingOut || isChoosingParent)
        .onAppear { focusesAddress = true }
        // This picker belongs to the checkout sheet's own presentation host,
        // not the main window's directory/history importer modifier chain.
        .fileImporter(isPresented: $isChoosingParent, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                if let parent = try result.get().first {
                    let name = URL(string: repositoryAddress.trimmingCharacters(in: .whitespacesAndNewlines))?.lastPathComponent
                    let folder = name.flatMap { $0.isEmpty || $0 == "." || $0 == ".." ? nil : $0 } ?? "WorkingCopy"
                    localPath = parent.appendingPathComponent(folder, isDirectory: true).path
                    pathSelectionError = nil
                }
            } catch {
                if (error as NSError).code != NSUserCancelledError { pathSelectionError = error.localizedDescription }
            }
        }
    }
}
