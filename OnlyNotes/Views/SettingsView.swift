import SwiftUI
import UniformTypeIdentifiers

private enum KeyFileState {
    case unknown, missing, unreadable, invalidJSON, valid
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showKeyFilePicker = false
    @State private var keyFileValidationState: KeyFileState = .unknown

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
                statusLabel(for: appState.openAIKey, purpose: "summarization & AI chat")
            }

            Section("Google Cloud") {
                SecureField("API Key", text: $appState.googleAPIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.googleAPIKey, purpose: "Speech-to-Text transcription")
            }

            Section("Google Cloud Storage") {
                TextField("GCS Bucket Name", text: $appState.googleBucketName)
                    .textFieldStyle(.roundedBorder)
                bucketStatusLabel(for: appState.googleBucketName)

                Divider()

                HStack {
                    if appState.serviceAccountKeyPath.isEmpty {
                        Text("No key file selected")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Text(URL(fileURLWithPath: appState.serviceAccountKeyPath).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose File…") {
                        showKeyFilePicker = true
                    }
                }
                keyFileStatusLabel
            }
            .fileImporter(
                isPresented: $showKeyFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if let data = try? Data(contentsOf: url),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["client_email"] is String,
                       json["private_key"] is String {
                        appState.serviceAccountKeyPath = url.path
                        keyFileValidationState = .valid
                    } else {
                        keyFileValidationState = .invalidJSON
                    }
                case .failure:
                    keyFileValidationState = .unreadable
                }
            }

            Section("Brave Search") {
                SecureField("API Key", text: $appState.braveSearchAPIKey)
                    .textFieldStyle(.roundedBorder)
                statusLabel(for: appState.braveSearchAPIKey, purpose: "web context in notes")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 560)
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

    @ViewBuilder
    private func bucketStatusLabel(for bucket: String) -> some View {
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("Required for audio upload & transcription", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.10))
                .font(.caption)
        } else {
            Label("Bucket name saved", systemImage: "checkmark.circle")
                .foregroundStyle(Color.onAccent)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var keyFileStatusLabel: some View {
        switch keyFileValidationState {
        case .unknown:
            if appState.serviceAccountKeyPath.isEmpty {
                Label("Required for audio upload", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.10))
                    .font(.caption)
            } else {
                Label("Key file configured", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.onAccent)
                    .font(.caption)
            }
        case .missing:
            Label("Required for audio upload", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.10))
                .font(.caption)
        case .unreadable:
            Label("Could not read file", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        case .invalidJSON:
            Label("Not a valid service account key", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        case .valid:
            Label("Service account key valid", systemImage: "checkmark.circle")
                .foregroundStyle(Color.onAccent)
                .font(.caption)
        }
    }
}
