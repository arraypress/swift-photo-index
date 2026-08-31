# swift-photo-index

An offline, indexed search engine for images and videos: OCR text, scene
labels, transcribed speech, EXIF, perceptual similarity and experimental face
clustering, in one incrementally-maintained SQLite index. The engine behind
the `pix` CLI.

```swift
import PhotoIndex

let store = try IndexStore(directory: indexDirectory)
let report = try await Indexer(store: store).index(source: FolderSource(paths: ["~/Pictures"]))
let hits = try SearchEngine(store: store).search("invoice 4021", kind: .screenshot)
```

## Design

**The index is the product.** Extraction is expensive and queries must not
be: every Vision pass writes into SQLite (FTS5 for text, blobs for
embeddings), and a query never touches an image. Re-indexing diffs source
fingerprints against the store and loads only what changed — touching one
file in a 300-image folder re-processes exactly one row.

**Sources are a seam.** `AssetSource` names assets cheaply (descriptors) and
loads one expensively on demand. `FolderSource` walks disk with zero
permissions — the whole test suite stands on it. `PhotoKitSource` speaks
PhotoKit and never touches the `.photoslibrary` bundle directly.

**Everything is Apple's own stack** — no third-party models or frameworks:

| Capability | Framework |
|---|---|
| OCR | Vision (`VNRecognizeTextRequest`) |
| Scene/object labels | Vision (`VNClassifyImageRequest`) |
| Similarity, dupes, face signatures | Vision (`VNGenerateImageFeaturePrint`) |
| Face detection | Vision (`VNDetectFaceRectanglesRequest`) |
| Speech → text | SpeechAnalyzer (via swift-speech-transcriber) |
| Photos library | PhotoKit |
| EXIF, decoding | ImageIO |
| Video frames | AVFoundation |
| Storage | system SQLite (FTS5) |

## Measured

On an M-series machine, 800×500 images:

- Indexing: **3.5 assets/s** synthetic corpus; **2.3–6 assets/s** on a real
  655-asset Photos library (601 photos, 25 screenshots, 39 videos — zero
  failures, both runs).
- Search: **0.03 s** against 300 and 655 assets alike.
- Incremental re-scan of an unchanged 300-image folder: **0.02 s**.
- Index size: ~5–8 MB per 1,000 assets.
- Faces: 10 real portraits (5 people, flipped pairs) clustered into exactly
  the 4 correct identities.

## The two calibrated numbers

Feature-print distances were measured on real photos, not guessed:

- A flipped or edited export sits **0.14–0.45** from its original; different
  photos sit **1.1–1.2**. Duplicates default: **0.5**.
- The same person's face crops range **0.19–0.59** across photos; different
  people never came closer than **1.1**. Cluster join: **0.8**.

Face identity is EXPERIMENTAL by design: it clusters feature prints of face
crops because Apple ships no public face-recognition API. It groups the
obvious cases and will split one person across haircuts and decades.

## What is deliberately absent

- **Semantic (meaning-based) image search.** The sanctioned path is Apple's
  MobileCLIP as a managed Core ML model; it is not in this build rather
  than half in it.
- **Geocoding inside the library.** `setPlace` accepts what a caller
  resolves; the one network call stays in the CLI behind an explicit flag.
  Coordinates are always captured.

## Layout

`Core/` store, indexer, search · `Ingest/` the source seam · `Extract/`
Vision passes · `Models/` shapes only · `Support/` every rule as a pure
function (query building, ranking, clustering, EXIF fields, diffing) ·
schema versioned with a migration path from day one.

## Requirements

- macOS 26+ (the SpeechAnalyzer floor), Apple silicon
- Swift 6

## License

MIT — see [LICENSE](LICENSE).
