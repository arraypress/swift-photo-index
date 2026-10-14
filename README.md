# swift-photo-index

An offline, indexed search engine for images and videos: OCR text, scene
labels, transcribed speech, file names, EXIF, search by meaning (SigLIP 2),
perceptual similarity and experimental face clustering, in one
incrementally-maintained SQLite index. The engine behind the `pix` CLI.

```swift
import PhotoIndex

let store = try IndexStore(directory: indexDirectory)
let embedder = try await SemanticEmbedder(folder: modelFolder)   // optional: meaning search
var options = Indexer.Options()
options.embedder = embedder
let report = try await Indexer(store: store).index(source: FolderSource(paths: ["~/Pictures"]),
                                                   options: options)
let engine = SearchEngine(store: store)
let exact = try engine.search("invoice 4021", kind: .screenshot)
let byMeaning = try engine.search("dog on a beach",
                                  queryVector: try await embedder.embed(text: "dog on a beach"))
```

## Design

**The index is the product.** Extraction is expensive and queries must not
be: every Vision pass writes into SQLite (FTS5 for text, blobs for
embeddings), and a query never touches an image. Re-indexing diffs source
fingerprints against the store and loads only what changed — touching one
file in a 300-image folder re-processes exactly one row.

**Sources are a seam.** `AssetSource` names assets cheaply (descriptors) and
loads one expensively on demand, and says which stored locators it covers:
indexing one folder never forgets another (before 1.2.0 a run over folder B
dropped everything indexed from folder A). `FolderSource` walks disk with zero
permissions — the whole test suite stands on it. `PhotoKitSource` speaks
PhotoKit and never touches the `.photoslibrary` bundle directly.

**Apple's own stack, plus one open model.** Meaning search runs Google's
SigLIP 2 on Core AI; everything else is Apple's frameworks:

| Capability | Framework |
|---|---|
| OCR | Vision (`VNRecognizeTextRequest`) |
| Scene/object labels | Vision (`VNClassifyImageRequest`) |
| Similarity, dupes, face signatures | Vision (`VNGenerateImageFeaturePrint`) |
| Face detection | Vision (`VNDetectFaceRectanglesRequest`) |
| Speech → text | SpeechAnalyzer (via swift-speech-transcriber) |
| Search by meaning | SigLIP 2 base/16 224 (Google, Apache-2.0) on Core AI |
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

## Search by meaning

`SemanticEmbedder` loads the Core AI export of SigLIP 2 base/16 at 224
(`google/siglip2-base-patch16-224` @ `75de2d5`), published at
[arraypress/pix-siglip2-base-224](https://huggingface.co/arraypress/pix-siglip2-base-224)
(725 MB, pinned by commit in `SemanticEmbedder.revision`). The library loads
it from a folder; downloading it is the host's job (`pix` fetches it on first
use, checksummed). The tokenizer (Gemma BPE), the pixel preparation and the
normalisation are Swift, held to `transformers` by fixtures:

- Tokenizer ids identical on 10 strings (accents, emoji, CJK, Arabic, tabs,
  truncation). Text embeddings: worst cosine **0.9999993**. Images: **0.99999**
  at 224×224, **0.997** when resized (Core Graphics vs PIL resampling).

The indexer stores one float16 vector per image (a video: the mean of its
sampled frames), tagged with the model id, so a different model re-embeds
rather than mixing spaces. Search blends it with the words:

- **Literal words win.** A hit whose every query word was read off the
  pixels, spoken, in the file name, a place or a named person ranks above
  every match by meaning, so "invoice 4021" still finds the scan that says it.
  A word found only in a guessed Vision label is not literal.
- **Inside each tier, meaning orders**; text relevance only breaks near-ties.
- **The cut-off:** a picture matching by meaning alone needs cosine ≥ **0.09**.
  Measured on 1,000 COCO val2017 images × their 5,003 captions (5 million
  pairs): true pairs sit at 0.101 (5th percentile) / 0.150 (median); 99% of
  wrong pairs fall below 0.087. 0.09 keeps 97.5% of true pairs and drops
  99.1% of wrong ones — a floor against junk, not a verdict.

Measured on that COCO set (M-series, GPU):

| | R@1 | R@5 | R@10 |
|---|---|---|---|
| SigLIP 2 alone, caption → image | 0.720 | 0.916 | 0.959 |
| `SearchEngine.search` with the query vector | 0.719 | 0.911 | 0.948 |
| `SearchEngine.search` words only (before) | 0 | 0 | 0 |

Words alone find nothing because a caption's sentence is never in an OCR
text or a label set. Embedding costs **12 ms per image** and **4 ms per
query**; the model loads in ~1–2 s. Scoring a query against **21,000** stored
vectors takes **25–35 ms** warm (~0.2 s for the first query of a process).
Backfilling 1,000 already-indexed images took **16–17 s**.

**An index from 1.1.x** opens fine: schema 1 steps to 2 by adding the
`embeddings` table, nothing else is touched, and search keeps answering by
words until vectors exist. The next `Indexer.index` over a folder with an
embedder gives that folder's unchanged assets vectors without re-running OCR,
labels, faces or transcription; an interrupted run resumes. A 1.1.x build
refuses a schema-2 index plainly ("written by a newer build").

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

- **Geocoding inside the library.** `setPlace` accepts what a caller
  resolves; the one network call stays in the CLI behind an explicit flag.
  Coordinates are always captured.

## Layout

`Core/` store, indexer, search · `Ingest/` the source seam · `Extract/`
Vision passes · `Models/` shapes only · `Support/` every rule as a pure
function (query building, ranking, clustering, EXIF fields, diffing) ·
schema versioned with a migration path from day one.

## Requirements

- macOS 27+ (Core AI, for the meaning model), Apple silicon
- Swift 6.2

The parity tests need the model and skip without it: they look at
`$PIX_MODEL`, then `Tools/exports/` (a fresh `uv run Tools/export_siglip2.py`),
then `~/Library/Application Support/pix`.


## The audit

`Auditor` runs a privacy scan over an existing index: what in this library
would its owner regret syncing, sharing or leaving on a sold machine?

Almost everything is a query over data the index already holds — OCR text,
coordinates, faces — so the pass is fast (a 13-asset corpus audits in
0.2 s). The rules, each pure and pinned by tests that never hold a real
sensitive value:

- **Cards** — 13–19 digit runs that pass Luhn, network-identified
  (swift-credit-card-validator).
- **Passport MRZ** — a 44-character TD3 line whose document, birth-date
  and expiry check digits (ICAO 7-3-1) all validate. Three checksums do
  not happen to OCR noise.
- **IBAN** — cut to the country's registered length, confirmed by mod-97.
- **Secrets** — swift-secret-scanner's concrete patterns over the OCR text
  (API keys photographed in screenshots). Entropy rules stay off: OCR text
  is exactly the noise they false-fire on.
- **Home inference** — the densest ~100 m cell of the library's
  coordinates is presumptively home; GPS within 100 m of it is the
  highest-severity location finding.
- **File passes** (folder assets only): serial numbers and owner names
  read from image headers, and `RecognizeDocumentsRequest` on OCR-dense
  images — a photographed document is a finding in itself.

Every excerpt is masked at construction (`••••4242`, `P<IRL•••`); the
matched value exists in no field, so a finding is safe to print anywhere.

What it cannot do: nudity detection (SensitiveContentAnalysis is
entitlement-gated away from command-line tools), text below the OCR floor,
and file passes on Photos-library assets (they would need full image-data
requests; index findings still apply).

## License

MIT — see [LICENSE](LICENSE).
