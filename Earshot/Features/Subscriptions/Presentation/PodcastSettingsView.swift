import SwiftUI
import SwiftData
import UIKit
import UserNotifications

/// Per-podcast settings sheet. Opened from a toolbar button on `EpisodeListView`.
/// All controls bind directly to the `Podcast` SwiftData model — changes persist
/// immediately without a save button.
///
/// Settings without a matching model field (e.g. per-podcast auto-download count)
/// are deferred to a future issue once the data agent adds them to the model.
struct PodcastSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings

    /// Bumped each time the notification toggle is switched ON — or the
    /// "Enable Notifications" button below is tapped, which just bumps this
    /// same token to reuse the identical request flow. A `.task(id:)` keyed on
    /// this token owns the async `requestAuthorization()` call so it runs with
    /// the view's lifetime rather than in an unowned `Task {}` that SwiftUI may
    /// tear down before it reaches the system prompt (#421).
    @State private var authRequestToken = 0
    /// iOS-level notification authorization, or `nil` before the first check
    /// completes. Checked on appear, after any authorization request, and
    /// whenever the app returns to active (e.g. after visiting Settings) —
    /// distinguishing `.denied` from `.notDetermined` matters because they
    /// need different remedies: Settings only has an entry for this app once
    /// it has genuinely been denied, never for `.notDetermined` (#600, #602).
    @State private var authorizationStatus: UNAuthorizationStatus?

    /// Factory for the notification service, injectable so a test can supply a
    /// mock `NotificationScheduling` and assert the permission request fires.
    var makeNotificationService: () -> NotificationService = { NotificationService() }

    // MARK: Speed options

    /// Speed override options shown in the Picker.
    /// nil = fall back to the global setting.
    private static let speedOptions: [(label: String, value: Double?)] = {
        var options: [(String, Double?)] = [("Use global", nil)]
        let speeds: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
        for s in speeds {
            // Format without trailing zeros: 1.0 → "1", 1.25 → "1.25"
            let formatted = s.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(s))
                : String(s)
            options.append(("\(formatted)×", s))
        }
        return options
    }()

    /// Test-visible accessor for speed options. Only use in tests.
    static var speedOptionsForTesting: [(label: String, value: Double?)] { speedOptions }

    /// Test-visible accessor for intro-skip options. Only use in tests.
    static var introSkipOptionsForTesting: [(label: String, value: Int?)] { introSkipOptions }

    // MARK: Intro skip options (#456)

    private static let introSkipOptions: [(label: String, value: Int?)] = [
        ("Off", nil),
        ("5 seconds", 5),
        ("10 seconds", 10),
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("45 seconds", 45),
        ("1 minute", 60),
        ("1.5 minutes", 90),
    ]

    // MARK: Queue age limit options

    private static let queueAgeLimitOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("1 day", 1),
        ("2 days", 2),
        ("3 days", 3),
        ("5 days", 5),
        ("1 week", 7),
        ("2 weeks", 14),
        ("3 weeks", 21),
        ("30 days", 30),
    ]

    // MARK: Inbox episode count options

    private static let inboxMaxOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("1 episode", 1),
        ("3 episodes", 3),
        ("5 episodes", 5),
        ("10 episodes", 10),
        ("20 episodes", 20),
    ]

    // MARK: Inbox age limit options (stored as hours in the model)

    private static let inboxAgeLimitOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("12 hours", 12),
        ("1 day", 24),
        ("2 days", 48),
        ("7 days", 168),
        ("14 days", 336),
    ]

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                playbackSection
                queueSection
                inboxSection
                notificationsSection
            }
            .navigationTitle("Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Done")
                    .accessibilityHint("Closes podcast settings")
                }
            }
        }
    }

    // MARK: Sections

    private var playbackSection: some View {
        Section {
            speedPicker
            introSkipPicker
        } header: {
            Text("Playback")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var queueSection: some View {
        Section {
            Toggle("Add new episodes to queue", isOn: autoQueueBinding)
            queueAgeLimitPicker
        } header: {
            Text("Queue")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var inboxSection: some View {
        Section {
            // Only relevant in opt-in mode (#668): with "Opt-in podcasts only"
            // off, every podcast is in the inbox by default and this toggle
            // has nothing to opt into. Shown above the limit pickers below —
            // a count/age cap is meaningless for a podcast that can't join the
            // inbox at all, so this ordering matters for VoiceOver users
            // navigating top to bottom. A plain Toggle gets the system
            // "On"/"Off" announcement for free, matching `autoQueue` above.
            if settings.inboxOptInOnly {
                Toggle("Include in Inbox", isOn: $podcast.inboxIncluded)
            } else {
                // Companion to the opt-in Toggle above, for normal mode (#671):
                // with "Opt-in podcasts only" off, every podcast is in the
                // inbox by default and this is the only way to keep one
                // specific noisy podcast out of it. Mutually exclusive with
                // the branch above since only one inbox mode is ever active.
                Toggle("Exclude from Inbox", isOn: $podcast.inboxExcluded)
            }
            inboxMaxPicker
            inboxAgeLimitPicker
        } header: {
            Text("Inbox")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            if settings.inboxOptInOnly {
                Text("\"Opt-in podcasts only\" is on in Inbox settings, so new episodes only appear in the inbox for podcasts you include here.")
            } else {
                Text("New episodes from this podcast appear in the inbox unless you exclude it here.")
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Notify on new episodes", isOn: notificationEnabledBinding)
                // Request notification permission the first time the user turns
                // this on. The async request is owned by a `.task(id:)` keyed on
                // `authRequestToken` (below) — NOT a bare `Task {}` — so it is
                // guaranteed to run and be awaited with the view's lifetime even
                // though writing a SwiftData @Model property doesn't reliably
                // fire `.onChange` (the model diffs old == new by the time
                // SwiftUI compares) (#421). requestAuthorization() is idempotent:
                // it never re-prompts once the user has decided (#72). Re-check
                // status afterward so a denial/grant is reflected immediately,
                // without waiting for the sheet to reopen (#600).
                .task(id: authRequestToken) {
                    guard authRequestToken > 0 else { return }
                    await makeNotificationService().requestAuthorization()
                    // Announce only on THIS path (a live toggle flip or a tap on
                    // "Enable Notifications" below), not the silent appear/
                    // scenePhase checks — a user who just asked for
                    // notifications and hit a standing problem needs to hear
                    // that it didn't work, since nothing else here tells them
                    // (#600).
                    await refreshAuthorizationStatus(announceIfStillProblematic: true)
                }
            // Only relevant once the user has actually asked for notifications
            // on this show — a denied/undetermined status is moot noise while
            // the toggle is off.
            if podcast.notificationEnabled == true {
                // Icon carries the warning color, text stays at label contrast
                // (never color alone) — matches the app's established
                // icon-carries-color error pattern (AddFeedView, #462).
                switch authorizationStatus {
                case .denied:
                    // Settings has an entry for this app once it's genuinely
                    // been asked and denied — "Open Settings" is the correct
                    // remedy here.
                    Label {
                        Text("Notifications are turned off for Earshot. Enable them in Settings to get new episode alerts.")
                    } icon: {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.orange)
                    }
                    Button("Open Settings") { openSystemSettings() }
                        .accessibilityHint("Opens the Settings app to Earshot's notification permissions")
                case .notDetermined:
                    // No Settings entry exists yet for an app that's never been
                    // asked (#602) — "Open Settings" would lead nowhere. The
                    // remedy is to actually ask, which reuses the exact same
                    // request flow as the toggle by bumping the same token.
                    Label {
                        Text("Notifications haven't been turned on for Earshot yet.")
                    } icon: {
                        // Plain `bell`, not `bell.badge` — the badge glyph reads
                        // as "you have a pending notification" to a sighted
                        // user scanning icons, the opposite of "not yet
                        // enabled." VoiceOver only speaks the Text either way.
                        Image(systemName: "bell")
                            .foregroundStyle(.orange)
                    }
                    Button("Enable Notifications") { authRequestToken += 1 }
                        .accessibilityHint("Asks iOS for permission to send notifications")
                default:
                    EmptyView()
                }
            }
        } header: {
            Text("Notifications")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Sends a notification when new episodes are detected during a background refresh.")
        }
        // Checked once when the sheet appears, so a standing problem from a
        // PRIOR session shows up without needing to toggle anything (#600),
        // and again whenever the app returns to active — e.g. after visiting
        // Settings and back, so the sheet doesn't need to be closed/reopened
        // to reflect a change made there (#602). Both silent: neither is a
        // live user action in this view, so nothing to announce.
        .task {
            await refreshAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshAuthorizationStatus() }
        }
    }

    /// Re-reads authorization status. `announceIfStillProblematic` fires a
    /// VoiceOver announcement when the status is anything other than granted
    /// after a live request — and only when the caller is responding to that
    /// live toggle-flip/button-tap, never on the silent appear/scenePhase
    /// checks, so those never re-announce already-known state.
    private func refreshAuthorizationStatus(announceIfStillProblematic: Bool = false) async {
        let status = await makeNotificationService().currentAuthorizationStatus()
        authorizationStatus = status
        guard announceIfStillProblematic else { return }
        switch status {
        case .denied:
            Announcer.announce(
                "Notifications are off for Earshot in Settings. Enable them there to get alerts for this podcast."
            )
        case .notDetermined:
            Announcer.announce("Notifications are still not enabled for Earshot.")
        default:
            break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Binding for the "Notify on new episodes" toggle. The `set` performs the
    /// model write AND, when the toggle goes ON, bumps `authRequestToken` so the
    /// `.task(id:)` above runs `requestAuthorization()` with the view's lifetime.
    /// Doing the permission trigger here (rather than via `.onChange` on the
    /// @Model property) is the fix for #421: the toggle now reliably surfaces the
    /// iOS permission prompt the first time it is switched on.
    private var notificationEnabledBinding: Binding<Bool> {
        Binding(
            // `notificationEnabled` is `Bool?` (nil = off, see Podcast / #425);
            // read nil as false so it can drive a `Toggle(isOn:)`.
            get: { podcast.notificationEnabled ?? false },
            set: { isOn in
                let decision = NotificationPermissionTrigger.apply(newValue: isOn)
                podcast.notificationEnabled = decision.persistedValue
                if decision.shouldRequestAuthorization { authRequestToken += 1 }
            }
        )
    }

    // MARK: Pickers

    // Adjustable options reuse the existing curated lists (sentinel first), so a
    // VoiceOver flick steps through them; the visual menu still opens on tap.

    private var speedAdjustableOptions: [AdjustableOptionPicker<Double?>.Option] {
        Self.speedOptions.map {
            .init(value: $0.value, title: $0.label, spoken: speedAccessibilityLabel(for: $0))
        }
    }

    private var introSkipAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.introSkipOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var queueAgeAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.queueAgeLimitOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var inboxMaxAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.inboxMaxOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var inboxAgeAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.inboxAgeLimitOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var speedPicker: some View {
        AdjustableOptionPicker(
            "Playback speed",
            options: speedAdjustableOptions,
            selection: speedOverrideBinding,
            hint: "Playback speed for this podcast. Use global uses the app-wide setting. Flick up for faster."
        )
    }

    private var introSkipPicker: some View {
        AdjustableOptionPicker(
            "Skip intro",
            options: introSkipAdjustableOptions,
            selection: introSkipBinding,
            hint: "Automatically skips this much time the first time you play a new episode of this podcast. Resuming an episode you already started never skips again."
        )
    }

    private var queueAgeLimitPicker: some View {
        AdjustableOptionPicker(
            "Remove from queue after",
            options: queueAgeAdjustableOptions,
            selection: queueAgeLimitBinding,
            hint: "Episodes older than this are automatically removed from the queue"
        )
    }

    private var inboxMaxPicker: some View {
        AdjustableOptionPicker(
            "Inbox episode limit",
            options: inboxMaxAdjustableOptions,
            selection: inboxMaxBinding,
            hint: "Maximum number of episodes from this podcast in the inbox at one time"
        )
    }

    private var inboxAgeLimitPicker: some View {
        AdjustableOptionPicker(
            "Remove from inbox after",
            options: inboxAgeAdjustableOptions,
            selection: inboxAgeLimitBinding,
            hint: "Episodes older than this are automatically removed from the inbox"
        )
    }

    // MARK: Bindings

    /// Preserves the native Toggle's label, value, traits, focus, and system
    /// announcement while adding the approved false -> true enrollment behavior.
    private var autoQueueBinding: Binding<Bool> {
        Binding(
            get: { podcast.autoQueue },
            set: { newValue in
                QueueRepository(context: modelContext)
                    .setAutoQueue(newValue, for: podcast)
            }
        )
    }

    /// Maps between `Optional<Double>` on the model and the Picker's tag type.
    private var speedOverrideBinding: Binding<Double?> {
        Binding(
            get: { podcast.speedOverride },
            set: { podcast.speedOverride = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model (introSkipSeconds) and the Picker.
    private var introSkipBinding: Binding<Int?> {
        Binding(
            get: { podcast.introSkipSeconds },
            set: { podcast.introSkipSeconds = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model and the Picker's tag type.
    private var queueAgeLimitBinding: Binding<Int?> {
        Binding(
            get: { podcast.queueAgeLimitDays },
            set: { podcast.queueAgeLimitDays = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model (inboxMaxEpisodes) and the Picker.
    ///
    /// The setter ALSO writes the value through to the feed-URL-keyed AppSetting
    /// (`podcast_inbox_cap_<feedURL>`) so the cap survives unsubscribe →
    /// re-subscribe, where a fresh `Podcast` is created with a nil cap (#548).
    /// The model field stays the live source of truth for every existing flow.
    ///
    /// This write-through is also the lazy backfill for existing subscribers who
    /// set a cap before the keyed setting existed: their current `Podcast` rows
    /// still hold the cap (which is all any live path reads), and the keyed copy
    /// only matters on a future re-subscribe — so persisting it on their next
    /// edit is sufficient and no launch migration is needed.
    private var inboxMaxBinding: Binding<Int?> {
        Binding(
            get: { podcast.inboxMaxEpisodes },
            set: { newValue in
                podcast.inboxMaxEpisodes = newValue
                AppSettingsStore(context: modelContext)
                    .setPodcastInboxCap(newValue, forFeedURL: podcast.feedURL)
            }
        )
    }

    /// Maps between `Optional<Int>` on the model (inboxAgeLimitHours) and the Picker.
    private var inboxAgeLimitBinding: Binding<Int?> {
        Binding(
            get: { podcast.inboxAgeLimitHours },
            set: { podcast.inboxAgeLimitHours = $0 }
        )
    }

    // MARK: Helpers

    private func speedAccessibilityLabel(for option: (label: String, value: Double?)) -> String {
        guard let value = option.value else { return "Use global speed setting" }
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(value)
        return "\(formatted) times speed"
    }
}
