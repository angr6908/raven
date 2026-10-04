import SwiftUI

struct AddAccountSheet: View {
    let kind: AccountKind
    private let store = AccountsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var authJson = ""
    @State private var note = ""
    @State private var callback = ""

    var body: some View {
        NavigationStack {
            Form {
                Notice(message: store.error)
                switch kind {
                case .workbuddy: workbuddy
                case .antigravity: antigravity
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add \(kind.title) Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(width: 540, height: kind == .workbuddy ? 520 : 400)
    }

    @ViewBuilder
    private var workbuddy: some View {
        Section {
            Button("Sign In with Browser", systemImage: "safari") {
                Task {
                    await store.startWorkbuddyOAuth()
                    if store.error == nil { dismiss() }
                }
            }
            .disabled(store.busy || store.wbOAuth != nil)
        } header: {
            Text("Browser")
        }

        Section {
            HStack {
                Button("Read Local Credential", systemImage: "arrow.down.doc") { readLocal() }
                    .disabled(store.busy)
                if !note.isEmpty {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $authJson)
                .font(.identifierSmall)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Radius.control))
            Button("Add Account") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || authJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Import")
        } footer: {
            Text("Read the credential the CodeBuddy desktop app wrote on this Mac, or paste the auth JSON yourself.")
        }
    }

    @ViewBuilder
    private var antigravity: some View {
        Section {
            Button(store.agOAuth == nil ? "Sign In with Google" : "Restart Sign-In", systemImage: "sparkles") {
                Task { await store.startAntigravityOAuth() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.busy)
        } header: {
            Text("Google")
        }

        Section {
            TextField("Callback URL", text: $callback,
                      prompt: Text("http://localhost:51121/oauth-callback?state=…&code=…"))
                .font(.identifierSmall)
            Button("Use Pasted Callback") { submitCallback() }
                .disabled(store.busy || store.agOAuth == nil
                          || callback.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Manual")
        } footer: {
            Text("On a machine without a browser, open the sign-in link elsewhere and paste the whole callback URL here.")
        }
    }

    private func readLocal() {
        note = ""
        Task {
            guard let result = await store.readWorkbuddyLocal(),
                  result.found, let json = result.authJson, !json.isEmpty else { return }
            authJson = json
            note = "Loaded \(result.nickname ?? result.uid ?? "account")" + (result.source.map { " from \($0)" } ?? "")
        }
    }

    private func submit() {
        let auth = authJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !auth.isEmpty else { return }
        Task {
            if await store.addWorkbuddy(authJson: auth) { dismiss() }
        }
    }

    private func submitCallback() {
        guard let session = store.agOAuth?.session else { return }
        let value = callback.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        Task {
            if await store.completeAntigravity(session: session, callback: value) { dismiss() }
        }
    }
}
