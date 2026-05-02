import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedMeeting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeeting: $selectedMeeting)
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a meeting or start recording")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            appState.loadMeetings()
        }
    }
}
