# Build 167 reset test — VoiceOver runbook

1. Confirm that build 167 is installed. Do not launch until ready.

2. Put `docs/incidents/2026-08-06-delete-all-local-data/opml/earshot-100.opml`
   on the iPhone using Files, AirDrop, or Finder file sharing.

   The file contains 100 subscriptions. Refetched episode counts will differ
   from the fixture counts.

3. Open the OPML file in Earshot and wait for the initial feed refresh to finish.

   Completion means the refresh activity has stopped and the library is stable.

4. Before resetting, note whether any download is in flight.

5. Open Settings, then Data.

6. Activate Delete all local data.

7. Confirm Delete everything.

8. Pass: the app stays alive, the existing announcement “All local data deleted.
   Podcasts you follow and downloads removed.” is heard, and onboarding appears
   in-app without a relaunch.

9. Failure: the app returns to the Home Screen, becomes silent, or bounces.

10. The point of no return is confirming Delete everything.

## Second pass: download in flight

11. After the clean pass, deliberately start a download and wait until it is
    visibly in flight.

12. While that download remains in flight, repeat steps 5–9.

No available OPML reproduces the incident store’s episodes-per-podcast shape.
Do not attempt to reproduce the original watchdog condition.
