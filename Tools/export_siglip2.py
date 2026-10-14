# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch==2.9.0", "numpy", "pillow", "coreai-torch==0.4.3", "coreai-core==1.0.0b3", "transformers==5.12.1"]
# ///
"""SigLIP 2 base/16 at 224 (Google, Apache-2.0) → pix-siglip2-base-224.aimodel, its tokenizer and fixtures.

    uv run Tools/export_siglip2.py [--out Tools/exports] [--dtype float16]

Two entry points in one asset:
  image: pixel_values [1,3,224,224] float32, already resized and normalised ((x/255 - 0.5)/0.5) → embedding [1,768]
  text:  ids [1,64] int32 (lower-cased, Gemma BPE, <eos>=1 appended, right-padded with <pad>=0) → embedding [1,768]
Both are the model's pooled outputs (what get_image_features / get_text_features return); the host
normalises to unit length. The tokenizer is written as two flat binary files the Swift side reads
without a JSON parse: the vocabulary and the merges as id triples in rank order.
Fixtures: texts with their ids and normalised embeddings, and two synthetic images with theirs, so
the Swift tokenizer, preprocessing and asset are each checked against transformers."""
import argparse, json, shutil, struct, time
from pathlib import Path
import numpy as np, torch, torch.nn as nn
from PIL import Image
from transformers import AutoModel, AutoProcessor, AutoTokenizer
import coreai_torch
from coreai.runtime import AIModelAssetMetadata

HERE = Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument("--name", default="google/siglip2-base-patch16-224")
ap.add_argument("--revision", default="75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2")
ap.add_argument("--asset", default="pix-siglip2-base-224.aimodel")
ap.add_argument("--dtype", default="float16", choices=["float16", "float32"])
ap.add_argument("--out", default=str(HERE / "exports"))
ap.add_argument("--fixtures", default=str(HERE.parent / "Tests/PhotoIndexTests/Fixtures/siglip"))
args = ap.parse_args()
LENGTH, SIZE = 64, 224

model = AutoModel.from_pretrained(args.name, revision=args.revision, dtype=torch.float32).eval()
proc = AutoProcessor.from_pretrained(args.name, revision=args.revision)
tok = AutoTokenizer.from_pretrained(args.name, revision=args.revision)

class Image_(nn.Module):
    def __init__(self, m): super().__init__(); self.v = m.vision_model
    def forward(self, pixel_values): return self.v(pixel_values=pixel_values).pooler_output
class Text_(nn.Module):
    def __init__(self, m): super().__init__(); self.t = m.text_model
    def forward(self, ids): return self.t(input_ids=ids).pooler_output
image_net, text_net = Image_(model).eval(), Text_(model).eval()

def ids_for(texts):
    return tok([t.lower() for t in texts], padding="max_length", max_length=LENGTH, truncation=True, return_tensors="pt")["input_ids"].to(torch.int32)

out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
support = out / "pix-siglip2-support"; support.mkdir(exist_ok=True)
fx = Path(args.fixtures); fx.mkdir(parents=True, exist_ok=True)

# Tokenizer → vocab.bin (u32 count, then u32 length + UTF-8 bytes per id) and merges.bin (u32 count, then u32 left, right, merged per rank).
tj = json.loads(tok.backend_tokenizer.to_str())
vocab = tj["model"]["vocab"]; inv = sorted(vocab.items(), key=lambda kv: kv[1])
assert [i for _, i in inv] == list(range(len(inv)))
with open(support / "vocab.bin", "wb") as f:
    f.write(struct.pack("<I", len(inv)))
    for s, _ in inv:
        b = s.encode("utf-8"); f.write(struct.pack("<I", len(b))); f.write(b)
merges = tj["model"]["merges"]
with open(support / "merges.bin", "wb") as f:
    f.write(struct.pack("<I", len(merges)))
    for m in merges:
        a, b = (m if isinstance(m, list) else m.split(" ", 1))
        f.write(struct.pack("<III", vocab[a], vocab[b], vocab[a + b]))
config = {"model": args.name, "revision": args.revision, "dimension": model.config.vision_config.hidden_size,
          "image_size": SIZE, "mean": 0.5, "std": 0.5, "text_length": LENGTH, "pad": tok.pad_token_id, "eos": tok.eos_token_id,
          "unk": tok.unk_token_id, "lowercase": True, "space": "▁", "entry_points": {"image": "pixel_values", "text": "ids"}}
json.dump(config, open(support / "config.json", "w"), indent=1, ensure_ascii=False)
shutil.copy(support / "config.json", fx / "config.json")
print(f"tokenizer: {len(inv)} tokens, {len(merges)} merges", flush=True)

# Fixtures.
texts = ["a dog running on the beach", "The red car at the beach at sunset", "ERROR 517 EXCLUSIVITY VIOLATION",
         "  leading and trailing spaces  ", "two  spaces\tand a tab\nand a newline", "café résumé naïve — punctuation!!",
         "emoji 🎹🎛️ and CJK 漢字 and Arabic عربى", "x", "1234567890 numbers 3.14",
         " ".join(f"word{i}" for i in range(80))]
ids = ids_for(texts)
with torch.no_grad():
    temb = nn.functional.normalize(text_net(ids.long()), dim=-1)
    ref = nn.functional.normalize(model.get_text_features(input_ids=ids.long()).pooler_output if hasattr(model.get_text_features(input_ids=ids.long()), "pooler_output") else model.get_text_features(input_ids=ids.long()), dim=-1)
    print(f"text wrapper vs get_text_features max |diff| {(temb - ref).abs().max():.2e}", flush=True)
temb.numpy().astype(np.float32).tofile(fx / "text_embeddings.f32")
json.dump({"texts": texts, "ids": ids.tolist()}, open(fx / "text_fixture.json", "w"), ensure_ascii=False)

ys, xs = np.mgrid[0:SIZE, 0:SIZE]
square = np.stack([xs * 255 // (SIZE - 1), ys * 255 // (SIZE - 1), (255 - xs * 255 // (SIZE - 1))], -1).astype(np.uint8)
Image.fromarray(square).save(fx / "gradient-224.png")
yw, xw = np.mgrid[0:300, 0:400]
wide = np.stack([((xw // 40 + yw // 40) % 2) * 200 + 30, xw * 255 // 399, yw * 255 // 299], -1).astype(np.uint8)
Image.fromarray(wide).save(fx / "checker-400x300.png")
with torch.no_grad():
    embs = []
    for name in ["gradient-224.png", "checker-400x300.png"]:
        px = proc(images=Image.open(fx / name).convert("RGB"), return_tensors="pt")["pixel_values"]
        embs.append(nn.functional.normalize(image_net(px), dim=-1)[0])
    torch.stack(embs).numpy().astype(np.float32).tofile(fx / "image_embeddings.f32")
    px = proc(images=Image.open(fx / "gradient-224.png").convert("RGB"), return_tensors="pt")["pixel_values"]
    manual = torch.from_numpy(((square.astype(np.float32) / 255 - 0.5) / 0.5).transpose(2, 0, 1)[None])
    print(f"processor vs manual normalise at 224 (no resize): max |diff| {(px - manual).abs().max():.2e}", flush=True)

# Export.
dtype = torch.float16 if args.dtype == "float16" else torch.float32
t0 = time.time()
conv = coreai_torch.TorchConverter(mode=coreai_torch.TorchConverter.Mode.RELEASE)
inet, tnet = Image_(model.to(dtype)).eval(), Text_(model.to(dtype)).eval()
class Cast(nn.Module):
    def __init__(self, inner, castin): super().__init__(); self.inner, self.castin = inner, castin
    def forward(self, x): return self.inner(x.to(dtype) if self.castin else x).to(torch.float32)
with torch.no_grad():
    ex = torch.export.export(Cast(inet, True), (torch.zeros(1, 3, SIZE, SIZE),)).run_decompositions(coreai_torch.get_decomp_table())
    conv.add_exported_program(ex, input_names=["pixel_values"], output_names=["embedding"], entrypoint_name="image")
    ex = torch.export.export(Cast(tnet, False), (torch.ones(1, LENGTH, dtype=torch.int32),)).run_decompositions(coreai_torch.get_decomp_table())
    conv.add_exported_program(ex, input_names=["ids"], output_names=["embedding"], entrypoint_name="text")
program = conv.to_coreai()
meta = AIModelAssetMetadata()
meta.author = "Google — SigLIP 2 base/16 224; Core AI export by swift-photo-index"
meta.license = "Apache-2.0"
meta.model_description = (f"SigLIP 2 ({args.name}@{args.revision[:7]}), {args.dtype}. Entry 'image': pixel_values [1,3,224,224] float32 "
    "((x/255-0.5)/0.5, RGB, resized to 224x224) → embedding [1,768]. Entry 'text': ids [1,64] int32 (lower-cased Gemma BPE, "
    "<eos>=1 appended, right-padded with 0) → embedding [1,768]. Normalise both in the host; cosine ranks.")
meta.creation_date = int(time.time())
asset = out / args.asset
if asset.exists(): shutil.rmtree(asset)
program.save_asset(asset, meta)
print(f"saved {asset} ({sum(f.stat().st_size for f in asset.rglob('*'))/1e6:.0f} MB) in {time.time()-t0:.0f} s", flush=True)
