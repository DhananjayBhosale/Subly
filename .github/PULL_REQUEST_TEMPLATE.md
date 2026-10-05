## What and why

<!-- One short paragraph. Record the bug or constraint that motivated the change. -->

## Checks

Run on macOS 26, Apple Silicon. Tick what you ran, and say plainly what you did not.

- [ ] `swift test` passes
- [ ] `./Scripts/full_sweep.sh` (11 language cases), if you touched speech, engine, or caption logic
- [ ] `./Scripts/test_real_videos.sh`, if you touched timing, segmentation, or the engine
- [ ] UI change: ran the layout/crash matrix (`SUBLY_LAYOUT_CHECK` across `SUBLY_APPEARANCE=light|dark` and routes `empty`, `home`, `new`, `editor`)
- [ ] New logic is in `SublyCaptions` with a test where it could be (see `CueTiming.swift`)
- [ ] New colours go through `Palette` / `TrackPalette` as light and dark pairs that clear 4.5:1
- [ ] No copyrighted media, personal data, or secrets added
- [ ] Docs updated (`README.md`, and `docs/KNOWN_LIMITS.md` if a known gap changed)

## Not verified

<!-- Anything above you could not run, and why. -->
