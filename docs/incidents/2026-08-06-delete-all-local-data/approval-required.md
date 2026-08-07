# Delete all local data: approval record

Updated: 2026-08-07, Turn 2.

Status: **Turn 2 GATE FAIL. No shipping fix was implemented.** The measured
file-level reset meets the 3.0-second ceiling, but the mandatory Task 1 stop
condition fired because `LocalAppSetting` contains cached purchase entitlement
and subscription state.

## Decided by the user on 2026-08-07

The following scope decisions are authoritative and reproduced verbatim:

> D1. "Delete all local data" MUST delete LocalPodcastState, LocalEpisodeState,
> and LocalAppSetting. Leaving them is a defect.

> D2. The verified migration snapshot MUST be deleted by a Settings reset.

> D3. The acceptable ceiling without spoken feedback is 3.0 seconds, total,
> including all filesystem work. Confirmed by the user, not assumed.

Consequences already decided:

- Both V10 store sets are within reset scope, including the three device-local
  models and the split/identity-repair markers.
- The verified migration snapshot and its catalog/manifest state are within
  reset scope.
- A silent implementation may proceed only if the complete operation,
  including filesystem work, remains at or below 3.0 seconds.
- The user's tolerance for losing the current test library does not independently
  authorize any further shipped deletion scope.

## Still open — implementation blocker

### Cached purchase state in `LocalAppSetting`

The incident store contains these four rows:

```text
1,'earshot_plus_entitlement_product',''
3,'earshot_plus_entitled','false'
4,'earshot_plus_entitlement_last_synced','1786070483.862052'
5,'earshot_plus_active_subscription','false'
```

They are synchronously read during entitlement configuration and overwritten
after a verified StoreKit resync at
`Earshot/Features/Monetization/Data/EntitlementStore.swift:83-100` and
`:186-199`. The Turn 2 prompt requires implementation to stop when any local
key relates to purchases or subscriptions; that stop fired.

The blocking decision is whether D1 intentionally includes deletion of these
four cached entitlement facts and, if so, what ordering guarantees that no
purchase gate treats the fresh empty cache as authoritative before StoreKit
resynchronization. This investigation does not answer that product/purchase
question and made no StoreKit, entitlement, purchase, or paywall change.

### Post-reset destination

The existing reset remains on the Data screen; `DataSettingsView.factoryReset`
does not navigate (`Earshot/Features/Settings/Presentation/DataSettingsView.swift:116-123`).
Under D1, `onboarding_complete` is deleted. A fresh container resolves a false
or absent value to the onboarding destination
(`Earshot/App/EarshotApp.swift:490-495`). It is therefore unresolved whether a
completed reset should remain on Data, show onboarding immediately, or defer
that transition until another launch. The user prohibited changing the current
destination in Turn 2, so no destination or focus behavior changed.

### Artwork cache lifetime

The exact production singleton cannot be redirected to a test-owned directory.
The equivalent disposable `URLCache` reproduced issue #690's SQLite warning:
`database integrity compromised by API violation: vnode unlinked while in use`.
One preliminary removal also failed with `NSCocoaErrorDomain Code=513` and
underlying POSIX code 1. The safe lifetime boundary for the live singleton and
its `URLSession` must be established before shipping file-level deletion.

### Failure behavior

The existing success announcement must remain byte-for-byte and at its existing
time unless separately approved. It must be suppressed after any failed
destructive step. There is still no approved user-facing failure string,
failure surface, focus destination, or partial-failure behavior.

## Draft wording — approval required, not present in shipping code

These Turn 1 drafts remain non-shipping proposals. No string, label, value,
trait, focus behavior, rotor behavior, announcement, or timing was changed.

- **DRAFT:** “Deleting all local data.”
- **DRAFT:** “Deletion in progress.”
- **DRAFT:** “Still deleting all local data.”
- **DRAFT:** “Local data could not be deleted. Nothing was removed.”
- **DRAFT:** “Some local data could not be deleted.”
- Existing completion text, unchanged: “All local data deleted. Podcasts you
  follow and downloads removed.”

D3 and the measured 0.041066225-second mean mean that progress or heartbeat
copy is not needed for the measured simulator path. It remains drafted only,
not approved or shipped.

## Turn 2 measured decision table

| Option | Measured completion | Deletion scope | What VoiceOver hears | Failure mode / risk | Decision |
|---|---:|---|---|---|---|
| Current per-object reset | Present-WAL mean 146.253898142 s; checkpointed mean 170.819108508 s | Omits all three local models and snapshots | Unacceptable long silence, then existing success even after swallowed failures | ~998–1000 MB peak RSS; watchdog; save/filesystem errors swallowed | Rejected by D1, D2, and D3 |
| Batch delete | Relationship-free types succeed; cascading `Podcast` fails in the two-configuration container with 134060 | Could omit or include selected models, but cascade path does not complete | Failure only | `Entity named:Podcast not found for relationship named:episodes` | Diagnostic only |
| Test-only file-level reset | Five samples 0.046932667, 0.041100583, 0.041597375, 0.035484084, 0.040216417 s; mean 0.041066225 s | Both store sets, all 14 model types, verified snapshot, Downloads, artwork | Existing completion announcement can remain unchanged and at its existing schedule | Purchase-cache ordering and artwork-cache lifetime remain unresolved | Speed/scope/crash-safety conditions passed; purchase stop blocks implementation |

The test-only reset reused the #797 two-phase journal idea—`moving` rolls back,
`committed` finishes cleanup—but deliberately did **not** call
`ModelContainerFactory.eraseLibrary`. That recovery path requires a verified
snapshot before erasure and retains it afterward
(`Earshot/Data/Persistence/ModelContainerFactory.swift:255-267`;
`Earshot/Data/Persistence/MigrationBackupManager.swift:290-350`). The Settings
measurement had no snapshot precondition and quarantined the snapshot itself,
as D2 requires.
