import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $appState.appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("OpenAI") {
                SecureField("API Key", text: $appState.openAIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.openAIKey, purpose: "summarization, AI chat & fallback transcription")
            }

            Section("AssemblyAI") {
                SecureField("API Key", text: $appState.assemblyAIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.assemblyAIKey, purpose: "system audio transcription with speaker diarization")
            }

            Section("Brave Search") {
                SecureField("API Key", text: $appState.braveSearchAPIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.braveSearchAPIKey, purpose: "web context in notes")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 480)
    }

    @ViewBuilder
    private func statusLabel(for key: String, purpose: String) -> some View {
        if key.isEmpty {
            Label("Required for \(purpose)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.10))
                .font(.caption)
        } else {
            Label("API key saved", systemImage: "checkmark.circle")
                .foregroundStyle(Color.onAccent)
                .font(.caption)
        }
    }
}
