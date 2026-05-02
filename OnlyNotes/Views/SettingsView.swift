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

            Section("Google Cloud Storage") {
                TextField("GCS Bucket Name", text: $appState.googleBucketName)
                    .textFieldStyle(.roundedBorder)
                bucketStatusLabel(for: appState.googleBucketName)
            }

            Section("Brave Search") {
                SecureField("API Key", text: $appState.braveSearchAPIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.braveSearchAPIKey, purpose: "web context in notes")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 430)
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

    @ViewBuilder
    private func bucketStatusLabel(for bucket: String) -> some View {
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("Required for audio upload & transcription", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        } else {
            Label("Bucket name saved", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }
}
