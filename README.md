# photos analyze

A Mac app that tags your photo folders automatically: what's in each shot, how it was shot,
and the camera behind it. Everything runs on your Mac. No photos or tags leave your computer.

## Features

- **Automatic tags in three groups**
  - *In the shot*: subjects, scenery and activities (Beach, Mountain, Surfing, Dog…)
  - *Type of shot*: Portrait, Landscape, Long exposure, Telephoto, Sunset / sunrise, Aerial / drone…
  - *Camera & date*: camera, lens, year, month, time of day (in the photo's own time zone), format
- **Clean tag vocabulary**: synonyms are merged into one tag ("lamppost", "utility pole" → *Pole*),
  vague labels (colors, materials, "structure") are dropped, and small background objects
  aren't tagged. Broader tags are added automatically: *Surfing* → *Watersport* → *Sport*.
- **Learns from your edits**: tags you keep removing stop being generated.
- **Your edits always win**: tags you add are never removed, tags you remove or delete never
  come back, and merged tags always use your name, including after a full re-analysis.
- **Optional Apple Intelligence captions** and extra tags, using the on-device model.
- **Quality verdicts** from Apple's aesthetics score, which you can override and rename.
- **AI-edit detection** from metadata (C2PA Content Credentials, IPTC digital source type,
  Lightroom AI masks…).
- RAW + JPEG pairs and other same-name files are shown as one photo.
- Export tags as JSON or Finder tags, and import them back.
- **Claude integration** (optional, no API key needed): a live `photo-tags.json` and a `CLAUDE.md`
  in each folder let Claude Code review and tidy your tags. The app enforces the rules above, so
  Claude can't remove tags you added.

## Requirements

- macOS 27.2 or later
- Xcode 27 or later to build
- Apple Intelligence (optional) for captions

## Building

Open `photos analyze.xcodeproj` in Xcode and run the **photos analyze** scheme. No Apple
developer account is needed: without a team, Xcode signs the app to run on your Mac only. To
sign with your own account, pick your team under *Signing & Capabilities*.

To install a Release build in `/Applications`:

```sh
./install.sh
```

To sign `install.sh` builds with your own team or bundle ID without changing the project, create
a `signing.local.env` file next to it (it's git-ignored):

```sh
DEVELOPMENT_TEAM=ABCDE12345
BUNDLE_ID=com.yourname.photos-analyze
```

## How tagging works

1. **Apple Vision** classifies each image (1,300+ labels), detects faces, people, animals and text,
   and scores its aesthetics.
2. **`TagTaxonomy`** turns raw labels into library tags: it maps synonyms, drops noise and applies
   per-label confidence floors. Distinctive subjects need little confidence; generic clutter
   such as fences and windows is tagged only when it dominates the frame.
3. **`ShotClassifier`** combines camera metadata (focal length, shutter speed, depth data) with the
   Vision results to decide the type of shot.
4. Optionally, the **on-device Apple Intelligence model** writes a caption and names the photo's
   main subjects, rating how prominent each one is. Minor details are discarded.
5. Your merges, deletions and per-photo edits are applied last, so they always take precedence.

## Tests

Run the unit tests with **⌘U** in Xcode. The tests use in-memory storage and never modify the
app's real library or settings.

## Privacy

Analysis happens entirely on-device with Apple's frameworks. The app has no network code and
no analytics. It only reads folders you choose, and writes `photo-tags.json` and `CLAUDE.md`
into them (you can turn this off in Settings).

## License

MIT. See [LICENSE](LICENSE).
