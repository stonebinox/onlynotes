import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var meetings: [Meeting] = []

    @AppStorage("openAIKey") var openAIKey: String = ""
    @AppStorage("googleAPIKey") var googleAPIKey: String = ""

    func loadMeetings() {
        meetings = MeetingStore.shared.loadAll()
    }

    func deleteMeeting(_ meeting: Meeting) {
        MeetingStore.shared.delete(meeting)
        loadMeetings()
    }

    func saveMeeting(_ meeting: Meeting) {
        MeetingStore.shared.save(meeting)
        loadMeetings()
    }
}
