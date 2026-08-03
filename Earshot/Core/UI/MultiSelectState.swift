import Foundation
import SwiftData

/// The reusable selection-mode state for any list of ``PersistentModel`` rows
/// (folders phase 2, #757). Generic over item identity — it stores only
/// ``PersistentIdentifier`` values, never the models themselves — so the same
/// holder backs podcast multi-select here and episode multi-select in #758 with
/// no change.
///
/// Deliberately UI-free and side-effect-free: it does no announcing, focus, or
/// persistence. The owning view drives the VoiceOver story (announce
/// "Selection mode on/off", move `@AccessibilityFocusState`) around these pure
/// mutations, which keeps this holder fully unit-testable (toggle/count/clear)
/// without a running screen. See ``MultiSelectBar`` for the persistent action
/// bar and ``MultiSelectActionLabel`` for the count-carrying button labels.
@MainActor
@Observable
final class MultiSelectState {
    /// Whether selection mode is active. `false` restores the list's normal
    /// (navigate/rotor/swipe) row behavior.
    private(set) var isSelecting = false

    /// The identifiers of the currently selected rows. The source of truth for
    /// the live count shown in ``MultiSelectBar``'s primary button label.
    private(set) var selectedIDs: Set<PersistentIdentifier> = []

    init() {}

    /// The number of selected rows — the value the bottom bar's action labels
    /// interpolate ("Add 3 podcasts to folder").
    var count: Int { selectedIDs.count }

    /// Whether nothing is selected. Used to disable the batch actions.
    var isEmpty: Bool { selectedIDs.isEmpty }

    /// Enters selection mode with an empty selection. Idempotent.
    func enter() {
        isSelecting = true
        selectedIDs.removeAll()
    }

    /// Leaves selection mode and clears the selection. Idempotent. Callers pair
    /// this with the appropriate VoiceOver announcement and focus re-anchor —
    /// this method stays silent so a batch (which announces its own result) and
    /// a manual "Done" (which announces "Selection mode off") can differ.
    func exit() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    /// Whether `id` is currently selected.
    func isSelected(_ id: PersistentIdentifier) -> Bool {
        selectedIDs.contains(id)
    }

    /// Toggles `id` in or out of the selection and returns the new state (`true`
    /// if now selected). No announcement — an interruptive utterance on every
    /// tap is exactly what the accessibility bar forbids; the running count lives
    /// in the bar's button label and is announced there, debounced.
    @discardableResult
    func toggle(_ id: PersistentIdentifier) -> Bool {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return false
        }
        selectedIDs.insert(id)
        return true
    }

    /// Clears the selection but stays in selection mode.
    func clear() {
        selectedIDs.removeAll()
    }
}

/// Pure, testable copy for the count-carrying batch action labels. Shared by
/// podcast multi-select (#757) and episode multi-select (#758) — the caller
/// passes the item noun ("podcast" / "episode"), so the exact same button reads
/// "Add 3 podcasts to folder" or "Add 3 episodes to folder".
///
/// The label is the accessibility source of truth for the running count, so it
/// must always reflect the live selection; these are called fresh in each render
/// from ``MultiSelectState/count``.
enum MultiSelectActionLabel {
    /// "3 podcasts" / "1 podcast" — simple English pluralization for a noun
    /// phrase, matching ``FolderPickerView/itemPhrase(_:singular:)``.
    static func itemPhrase(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    /// "Add 3 podcasts to folder" (or "Add to folder" when nothing is selected —
    /// the button is disabled in that state, but its name still reads cleanly).
    static func addToFolder(count: Int, itemSingular: String) -> String {
        count == 0 ? "Add to folder" : "Add \(itemPhrase(count, singular: itemSingular)) to folder"
    }

    /// "Move 3 podcasts to folder".
    static func moveToFolder(count: Int, itemSingular: String) -> String {
        count == 0 ? "Move to folder" : "Move \(itemPhrase(count, singular: itemSingular)) to folder"
    }

    /// "Remove 3 podcasts from folder" — the in-folder-only destructive batch.
    static func removeFromFolder(count: Int, itemSingular: String) -> String {
        count == 0 ? "Remove from folder" : "Remove \(itemPhrase(count, singular: itemSingular)) from folder"
    }

    /// The polite, debounced "N selected" utterance the bar posts once the count
    /// settles. Empty for a zero count (nothing to announce).
    static func selectedCount(_ count: Int, itemSingular: String) -> String {
        count == 0 ? "" : "\(itemPhrase(count, singular: itemSingular)) selected"
    }
}
