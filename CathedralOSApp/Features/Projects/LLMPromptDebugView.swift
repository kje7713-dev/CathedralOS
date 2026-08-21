import SwiftUI

/// Debug-only collapsible box on the section output view.
/// Shows the LLM prompt that produced this output.
/// Kevin (2026-08-18 08:43 EDT): "Will remove it before shipping but need it to debug easier."
/// Remove the `#if DEBUG` block + the call site in GenerationOutputDetailView before shipping.
struct LLMPromptDebugView: View {
    let outputID: String

    // Default: show only the generate-story call_type (matches the 13:33 EDT
    // spec — the LLM Prompt Debug view should default to the Generation
    // Prompt, with optional Pipeline Diagnostics for post-generation calls
    // like embed-section-extract / embed-section-vectorize).
    @State private var generationPrompts: [LLMPrompt] = []
    @State private var pipelinePrompts: [LLMPrompt] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var isExpanded = false
    @State private var isPipelineExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Generation Prompt section — defaults to call_type=generate-story.
            Button(action: {
                isExpanded.toggle()
                if isExpanded && generationPrompts.isEmpty && pipelinePrompts.isEmpty && !isLoading {
                    Task { await loadPrompts() }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Generation Prompt")
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
                } else if generationPrompts.isEmpty && pipelinePrompts.isEmpty && !isLoading {
                    Text("No LLM prompts logged for this output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Render the first generation prompt as SYSTEM + USER + Response.
                    if let gen = generationPrompts.first {
                        promptBlock(label: "SYSTEM", text: extractField(from: gen.prompt, key: "system"))
                        promptBlock(label: "USER", text: extractField(from: gen.prompt, key: "user"))
                        if let response = gen.response, !response.isEmpty {
                            promptBlock(label: "Response", text: response)
                        }
                    }

                    // Pipeline Diagnostics — only renders if there are
                    // post-generation prompts (embed-section-extract,
                    // embed-section-vectorize, etc.). Optional subsection so
                    // the user can see the cascade without it being the
                    // primary view.
                    if !pipelinePrompts.isEmpty {
                        Button(action: { isPipelineExpanded.toggle() }) {
                            HStack(spacing: 6) {
                                Image(systemName: isPipelineExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                Text("Pipeline Diagnostics")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if isPipelineExpanded {
                            Divider()
                            ForEach(pipelinePrompts) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.call_type)
                                        .font(.caption.bold())
                                        .foregroundColor(.secondary)
                                    promptBlock(label: "Prompt", text: p.prompt)
                                    if let r = p.response, !r.isEmpty {
                                        promptBlock(label: "Response", text: r)
                                    }
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func promptBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
                .textSelection(.enabled)
        }
    }

    /// Extracts a string field from the JSON-encoded prompt blob. The
    /// generate-story call stores `{"system":..., "user":...}`.
    private func extractField(from json: String, key: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json  // fall back to raw blob if not parseable
        }
        return (obj[key] as? String) ?? json
    }

    private func loadPrompts() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let service = LLMPromptService()
            // Default: only the generation prompt (per 13:33 EDT spec).
            generationPrompts = try await service.fetchPrompts(
                outputID: outputID,
                callTypes: ["generate-story"]
            )
            // Pipeline diagnostics: post-generation calls only.
            pipelinePrompts = try await service.fetchPrompts(
                outputID: outputID,
                callTypes: ["embed-section-extract", "embed-section-vectorize"]
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
