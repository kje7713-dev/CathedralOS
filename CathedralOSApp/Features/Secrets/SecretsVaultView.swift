import SwiftUI
import SwiftData

struct SecretsVaultView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    @State private var showAddSecret = false
    @State private var secretToEdit: Secret?

    var body: some View {
        NavigationStack {
            List {
                if secrets.isEmpty {
                    Text("No secrets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(secrets) { secret in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(secret.name)
                                .fontWeight(.medium)
                            Text(secret.alias)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { secretToEdit = secret }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteSecret(secret)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Secrets Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSecret = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSecret) {
            SecretFormView(secret: nil)
        }
        .sheet(item: $secretToEdit) { secret in
            SecretFormView(secret: secret)
        }
    }

    private func deleteSecret(_ secret: Secret) {
        try? KeychainService.delete(key: secret.keychainKey)
        modelContext.delete(secret)
    }
}

// MARK: - Secret Form

struct SecretFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var secret: Secret?

    @State private var name = ""
    @State private var alias = ""
    @State private var value = ""

    private var isEditing: Bool { secret != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Safe export text (alias)", text: $alias)
                }
                Section {
                    SecureField(isEditing ? "Update value" : "Secret value", text: $value)
                } header: {
                    Text("Value")
                } footer: {
                    Text("The value is stored in Keychain and never exported.")
                        .font(.caption)
                }
            }
            .navigationTitle(isEditing ? "Edit Secret" : "Add Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  alias.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let secret {
                    name = secret.name
                    alias = secret.alias
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)

        if let secret {
            secret.name = trimmedName
            secret.alias = trimmedAlias
            if !trimmedValue.isEmpty {
                try? KeychainService.saveString(key: secret.keychainKey, value: trimmedValue)
            }
        } else {
            let newSecret = Secret(name: trimmedName, alias: trimmedAlias)
            modelContext.insert(newSecret)
            if !trimmedValue.isEmpty {
                try? KeychainService.saveString(key: newSecret.keychainKey, value: trimmedValue)
            }
        }
        dismiss()
    }
}
