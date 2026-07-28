---
name: restyle-ceramic-product-photo
description: Apply a reproducible soft studio treatment to ceramic product photos, with a neutral gray wall and table, soft upper-left key light, lower-right cast shadow, preserved glaze detail, adaptive segmentation, and depth of field. Use when a user asks to restyle, retouch, batch-process, or give a consistent catalog or Instagram look to ceramic or pottery product images.
---

# Restyle Ceramic Product Photo

Apply the approved look through the bundled deterministic pipeline. Do not
recreate the treatment with an image-generation model or ad-hoc filters.

## Run

For one image:

```bash
python3 <skill-dir>/scripts/restyle.py input.jpg output.jpg
```

For every supported image in a folder:

```bash
python3 <skill-dir>/scripts/restyle.py input-folder output-folder
```

Omit the output to create `<name>-styled.jpg` or `<folder>-styled/`. Add
`--force` only when the user explicitly permits replacing existing outputs.

## Preserve reproducibility

- Use the bundled `preset.json` unchanged unless the user explicitly requests
  a different visual treatment.
- Let `restyle.py` create its versioned cache runtime. Never install packages
  into the user's system Python.
- Keep CPU inference, the pinned model checksum, exact dependency lock, fixed
  random seeds, EXIF orientation handling, and adaptive subject geometry.
- Treat a checksum mismatch as a hard failure.
- Expect the first run to download pinned Python packages and a roughly 170 MB
  segmentation model.
- Promise byte-identical reruns only on the same validated platform. Across
  supported macOS/Linux CPU systems, promise the same visual preset and
  regression metrics, not byte identity across numeric libraries.

## Verify output

Inspect the finished image before delivery. Confirm:

- all product feet and edges survive segmentation;
- the product rests on the table rather than floating;
- the soft key reads from upper left and the cast shadow travels lower right;
- the bright glaze remains detailed;
- the wall/table horizon does not cross the product;
- framing and EXIF orientation are correct.

If any check fails, preserve the output as evidence and ask for a concrete
visual preference before changing the preset.
