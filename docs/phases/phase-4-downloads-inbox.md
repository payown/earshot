# Phase 4: Downloads, Inbox, queue expiration

**Goal:** Episodes download to disk, new episodes land in Inbox for triage, Auto-Queue podcasts skip Inbox, and stale queue items expire to Recently Expired with a 7-day recovery window.

**Estimated duration:** 2-3 weeks (part-time)

## Prerequisites

- Phase 3 complete: Quick Actions wired, Settings screen exists
- `just_audio` can play from local file URLs (set url to `file://...`)

## Tasks

### 1. Download manager
- [ ] Add `download_status` tracking already in `episodes` table (done in Phase 1)
- [ ] Create `lib/features/downloads/` feature
- [ ] `DownloadManager` service using `dio` to download audio files to app documents directory
- [ ] Store downloaded file path in `episodes.download_path`
- [ ] Update `episodes.download_status` through: none → pending → downloading → downloaded / failed
- [ ] Wi-Fi-only enforcement: check `connectivity_plus` before starting download
- [ ] Download progress stream per episode
- [ ] Cancel in-flight download on request
- [ ] Add `download` Quick Action callback (was stub in Phase 3)

### 2. Auto-download on subscribe
- [ ] When subscribing, auto-download the N most recent episodes (default N=3)
- [ ] N configurable globally in Settings: 0, 1, 3 (default), 5, 10
- [ ] Store setting in a new `app_settings` drift table (key-value pairs)

### 3. Inbox flow
- [ ] New episodes arriving via feed refresh land in Inbox (status = `newEpisode`)
- [ ] Podcasts with `autoQueue = true` skip Inbox: episodes go straight to queue
- [ ] Inbox screen: list of new, untriaged episodes across all subscriptions
- [ ] Triage actions per episode: Add to queue, Mark as played (dismiss), Delete
- [ ] Inbox count badge on tab or nav item
- [ ] Wire Toggle Auto-Queue action on podcast rows (was stub in Phase 3)

### 4. Downloads screen
- [ ] List of all downloaded episodes
- [ ] Shows file size, date downloaded
- [ ] Delete download action (removes file, resets download_status to none)
- [ ] Recently Expired section (see Task 5)

### 5. Queue expiration
- [ ] Per-podcast `queue_age_limit_days` already in `podcasts` table
- [ ] Background check (run on app foreground): find queue items older than limit
- [ ] Move expired items to `recently_expired` drift table: `episode_id`, `expired_at`
- [ ] Wire Change Queue Age Limit Quick Action on podcast rows
- [ ] Recently Expired screen: episodes removed from queue, recoverable for 7 days
- [ ] Recovery: tap to add back to queue
- [ ] Cleanup job: delete `recently_expired` entries (and audio files) older than 7 days

### 6. Navigation structure
- [ ] Add bottom navigation bar (or tab bar) with: Inbox, Queue, Subscriptions, Downloads
- [ ] Badge on Inbox tab showing unread count
- [ ] All tabs accessible with VoiceOver (tab labels, selected state announced)

### 7. Tests
- [ ] Unit tests: DownloadManager state transitions
- [ ] Unit tests: queue expiration logic
- [ ] Widget tests: Inbox screen (empty state, episode list, triage actions)
- [ ] Widget tests: Downloads screen
- [ ] Widget tests: navigation tab bar (semantic labels, selected state)

## Definition of done

- Subscribing to a podcast downloads the 3 most recent episodes automatically (Wi-Fi only)
- New episodes land in Inbox; Auto-Queue podcasts go straight to queue
- Inbox triage actions work: add to queue, mark played, delete
- Queue age limit auto-expires items to Recently Expired
- Recently Expired shows for 7 days and can be restored to queue
- Downloads screen shows all downloaded files with delete option
- Bottom navigation with Inbox, Queue, Subscriptions, Downloads
- All new screens accessible: semantic labels, headings, empty states announced

## Commands to use during this phase

```bash
flutter pub add connectivity_plus

dart run build_runner build  # after adding app_settings and recently_expired tables

flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: download manager**
```
Read docs/phases/phase-4-downloads-inbox.md. Build the DownloadManager in lib/features/downloads/. Use dio to download audio files. Track progress via download_status in the episodes table. Enforce Wi-Fi-only using connectivity_plus. Wire the Download Quick Action that was a stub in Phase 3. Write unit tests for state transitions.
```

**Prompt 2: Inbox and auto-queue**
```
Implement the Inbox flow. New episodes from feed refresh land with status=newEpisode. Podcasts with autoQueue=true have their new episodes added to queue automatically. Build the Inbox screen with triage actions (add to queue, mark played, delete). Show episode count as a badge. Wire the Toggle Auto-Queue podcast Quick Action.
```

**Prompt 3: queue expiration and Recently Expired**
```
Add a recently_expired drift table (episode_id, expired_at). On app foreground, scan queue items older than each podcast's queue_age_limit_days and move them to recently_expired. Build the Recently Expired section in the Downloads screen. Allow restoring items to queue. Run a cleanup job deleting entries older than 7 days. Wire the Change Queue Age Limit podcast Quick Action.
```

**Prompt 4: bottom navigation**
```
Replace the subscriptions-only app with a bottom navigation bar: Inbox (with unread badge), Queue, Subscriptions, Downloads. All tabs labeled for screen readers. Selected state announced. Use IndexedStack to preserve scroll state between tabs.
```
