import SwiftUI

/// Debug-only collapsible box on the section output view.
/// Shows the LLM prompt that produced this output.
/// Kevin (2026-08-18 08:43 EDT): "Will remove it before shipping but need it to debug easier."
/// Remove the `#if DEBUG` block + the call site in GenerationOutputDetailView before shipping.
struct LLMPromptDebugView: View {
    let outputID: String

    @State private var prompts: [LLMPrompt] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                isExpanded.toggle()
                if isExpanded && prompts.isEmpty && !isLoading {
                    Task { await loadPrompts() }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("LLM Prompt (debug)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                if let error {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if prompts.isEmpty && !isLoading {
                    Text("No LLM prompts logged for this output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(prompts) { prompt in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(prompt.call_type)
                                    .font(.caption.bold())
                                Text(prompt.model)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let tokens = prompt.total_tokens {
                                    Text("\(tokens) tok")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let ms = prompt.duration_ms {
                                    Text("\(ms)ms")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text("Prompt")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            Text(prompt.prompt)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                                .textSelection(.enabled)
                            if let response = prompt.response, !response.isEmpty {
                                Text("Response")
                                    .font(.caption2.bold())
                                    .foregroundColor(.secondary)
                                Text(response)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    private func loadPrompts() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let service = LLMPromptService()
            prompts = try await service.fetchPrompts(outputID: outputID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
