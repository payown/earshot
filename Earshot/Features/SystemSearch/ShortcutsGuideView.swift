import AppIntents
import SwiftUI

struct ShortcutsGuideView: View {
    var body: some View {
        List {
            Section("Ready to use") {
                ShortcutsLink()
                Text("Open Shortcuts, select Earshot, and try Resume Listening, Play Episode, Skip Forward, Skip Back, Pause, Next Chapter, Previous Chapter, or Clear and Play Next.")
            }
            Section("Action button and gestures") {
                Text("In iPhone Settings, choose Action Button, then Shortcut, and select an Earshot shortcut. You can also assign a saved shortcut to Back Tap under Accessibility, Touch. Available gestures depend on your device and settings.")
                Text("For a play/pause toggle, create a shortcut with Control Playback in Earshot and choose Play or pause. Resume Listening only plays; running it again will not pause.")
            }
            Section("Make your own") {
                Text("Add an Earshot action in Shortcuts and choose its parameters. Control Playback includes chapter and Queue navigation, playback speed, continuous play, volume boost, silence trimming, sleep timers, seeking, and bookmarks.")
                Text("Bedtime listening: Resume Listening, then Control Playback with Set sleep timer. Set the timer after starting the episode so your existing episode-change behavior does not cancel it.")
                Text("Remember this moment: use Control Playback with Bookmark current position, or Get Playback Position to pass the time to another action.")
                Text("Choose from your Queue: Get Episodes from Earshot with List set to Queue, then Choose from List, then Play Episode in Earshot.")
                Text("Discover a show: Search Podcast Directory, then Choose from List, then Play or Queue a Directory Podcast. Get Podcasts by Category can replace the search step.")
                Text("Play Queue starts the stored Queue from the beginning. Its Shuffle option rearranges that Queue. Podcast or Folder grouping can affect subsequent playback order.")
            }
            Section("Before you start") {
                Text("Finish Earshot setup first. Enable Include library in Siri and Search to select saved podcasts and episodes or return their information. Public directory searches and playback controls do not require that setting.")
                Text("Controls run without opening Earshot when your library is ready. After an update that requires library preparation, open Earshot once to finish it. iOS may require unlocking for some actions or device states.")
                Text("Clear and Play Next marks only the current queued episode played and removes it, then advances. Your download deletion preference still applies. Next episode leaves the current episode in Queue with its saved position.")
                Text("Chapter actions use the episode’s available chapters. They report when chapters have not loaded or are missing. They do not generate chapters or detect advertisements.")
            }
        }
        .navigationTitle("Shortcuts guide")
    }
}
