import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $appState.openAIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.openAIKey, purpose: "summarization & AI chat")
            }

            Section("Google Cloud") {
                SecureField("API Key", text: $appState.googleAPIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.googleAPIKey, purpose: "transcription & speaker detection")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 280)
    }

    @ViewBuilder
    private func statusLabel(for key: String, purpose: String) -> some View {
        if key.isEmpty {
            Label("Required for \(purpose)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        } else {
            Label("API key saved", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }
}
