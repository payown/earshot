# Morning device test — blocked by Gate 3

Michael,

Do not run a simulator or device reset test from this investigation branch.
Gate 3 fired because the fastest successful scope-preserving real-store
candidate took 121.419712 seconds, above the 3.0-second VoiceOver silence
threshold. The run therefore stopped implementation as required.

No reset fix was written. The diagnosis branch later passed its required pre-PR
`tool/local-ci.sh` gate with 1,733 tests executed, 30 skipped, and 0 failed, but
that is not post-fix verification because no shipping fix exists. No simulator
reproduction build was prepared. Build 166 was not created. No device binary
was compiled. Consequently there is no artifact path and no truthful install
command to provide.

The required test order remains **simulator first, device second**, but neither
test is authorized or runnable from this branch. There is no new behavior to
listen for: installing the unchanged build would reproduce the known watchdog
defect and must not be used as a substitute test.

For any eventual approved device test, the destructive confirmation is the
point of no return after which the on-device test library may be gone. That test
destroys the on-device library. The Mac container backup is the only copy, and
there is no proven route to restore that container onto the phone.
