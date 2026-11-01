# cbztopdf.sh

Convert CBZ comic archives (and image folders) to PDF — optimised for reading manhwa/webtoon on a PDF viewer.

**Version 2.0.0** — works on ImageMagick 6 and 7, mawk and gawk, Bash 4.4+.

---

## Features

- **Webtoon mode** — stacks vertical-strip images into reader-friendly pages, cutting at blank gaps so panels never split mid-sentence.
- **Pages mode** — one PDF page per source image; sRGB/gray JPEGs that need no changes are embedded byte-identical (zero quality loss).
- **Auto-detection** — webtoon vs. pages chosen automatically from image aspect ratios and edge content.
- Works with CBZ files **and** plain image folders.
- Parallel processing (`-j`), recursive folder scan (`-R`), forced overwrite (`--force`).
- Correct output for Korean/Unicode filenames, CMYK, alpha, EXIF-rotated images.

---

## Requirements

| Tool | Minimum |
|------|---------|
| Bash | 4.4 |
| ImageMagick | 6 or 7 (`convert`/`identify` or `magick`) |
| unzip | any |
| awk | mawk or gawk |
| od, sort, find, xargs | standard POSIX |

### Termux (Android)

```sh
pkg install imagemagick unzip gawk coreutils findutils
```

---

## Installation

```sh
git clone https://github.com/Sac-94/CBZ-To-PDF.git
cd CBZ-To-PDF
chmod +x cbztopdf.sh
# optionally symlink into your PATH:
ln -s "$PWD/cbztopdf.sh" ~/bin/cbztopdf
```

---

## Usage

```
cbztopdf.sh [OPTIONS] FILE_OR_FOLDER ...
```

Each input can be a `.cbz` file or a folder of images. The output PDF is placed **next to** the source by default; use `-o` to override.

### Examples

```sh
# Auto-detect mode, output next to the source
cbztopdf.sh "Solo Leveling Ch.1.cbz"

# Force webtoon mode
cbztopdf.sh --webtoon "Solo Leveling Ch.1.cbz"

# All CBZ files in the current folder
cbztopdf.sh -a

# Recurse into sub-folders, output under ./out/ (mirrors layout)
cbztopdf.sh -R -o out/

# Parallel (3 workers), resize to 900 px wide, 70% JPEG quality
cbztopdf.sh -j 3 -w 900 -Q 70 -a

# Pages mode with a custom page-height ratio
cbztopdf.sh --webtoon --page-ratio 4 "Chapter1.cbz"

# Convert an image folder
cbztopdf.sh my_manhwa_folder/
```

---

## Options

### Input / output

| Option | Description |
|--------|-------------|
| `-f FILE` / `--file FILE` | Convert a single file (same as passing it as an argument) |
| `-a` / `--all` | Convert all `.cbz` files in the current directory |
| `-R` / `--recursive` | Also scan sub-directories (combine with `-a` or `-o`) |
| `-o DIR` / `--output-dir DIR` | Write PDFs to DIR instead of next to each source; with `-R` the sub-folder layout is mirrored |
| `--force` | Overwrite existing PDFs |
| `--` | End of options; everything after is treated as a file path |

### Mode

| Option | Description |
|--------|-------------|
| `--webtoon` | Force webtoon mode |
| `--no-webtoon` | Force pages mode |
| `--page-ratio R` | Webtoon page height = width × R (default 3) |
| `--hard-cut` | Cut webtoon pages at exact positions even if no blank gap is found |

### Image quality

| Option | Description |
|--------|-------------|
| `-w N` / `--width N` | Max page width in pixels (default: source width, capped at 14 400) |
| `-Q N` / `--quality N` | JPEG quality for re-encoded images, 1–100 (default 85) |

### Performance

| Option | Description |
|--------|-------------|
| `-j N` / `--jobs N` | Parallel worker count (default 1) |

### Informational

| Option | Description |
|--------|-------------|
| `-v` / `--verbose` | Print per-page details and mode decisions |
| `-h` / `--help` | Show help |
| `--version` | Print version |

Long options can use `--opt=value` syntax.

---

## Webtoon mode details

1. The most common strip width becomes the page width W (capped by `--width`).
2. Each strip is scaled to W.
3. A 64-column grayscale row-variance profile detects blank rows (near-uniform colour).
4. Pages are cut inside blank gaps so artwork is never split. If no gap falls in the target range, the calmest available row is used.
5. Default page height ≈ W × 3 (change with `--page-ratio`).

**Auto-detection rules:**

- Webtoon if median image height/width ≥ 2.
- Otherwise, if ≥ 80 % of images share a width and the median ratio ≥ 1.2, eight sample images are checked: webtoon if ≥ 40 % of their top/bottom edges touch artwork.

---

## Output location

| Situation | PDF location |
|-----------|-------------|
| Default | Same folder as the source file/folder |
| `-o DIR` (single file) | `DIR/name.pdf` |
| `-o DIR` with `-R` | `DIR/relative/path/name.pdf` (layout mirrored) |

PDFs are written to a `.part` file and atomically renamed only on success. Temp directories are always cleaned up.

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All conversions succeeded |
| 1 | One or more conversions failed (or no valid images found) |

---

## Troubleshooting

### "webtoon mode needs raw pixel data" / webtoon falls back to pages mode

ImageMagick's `policy.xml` may block raw pixel output (`gray:-`). This is common on Debian/Ubuntu where the default policy also blocks PDF output and caps image dimensions at 16 384 px.

**Fix (edit `/etc/ImageMagick-6/policy.xml` or `/etc/ImageMagick-7/policy.xml`):**

```xml
<!-- change PS, PS2, PS3, EPS, PDF, XPS rights to read|write if needed -->
<policy domain="coder" rights="read|write" pattern="PDF" />
<!-- remove or raise the resource limits -->
<policy domain="resource" name="width" value="32KP"/>
<policy domain="resource" name="height" value="32KP"/>
```

Or use `--no-webtoon` to stay in pages mode without the fix.

### Termux: policy.xml not an issue

Termux's ImageMagick package ships without a restrictive policy, so raw output and PDF writing work out of the box.

### "No images found" / archive opens as 0 images

The CBZ may actually be a RAR archive renamed to `.cbz`. Check with `file archive.cbz`. If it says RAR, install `bsdtar` or `p7zip` and extract manually, or ask the source to provide a real ZIP-based CBZ.

### Large images are cropped or resized unexpectedly

Check the `width`/`height` resource limits in `policy.xml` (see above). Raise them to at least `32KP` or `64KP` for very tall webtoon strips.

### JPEG quality / file size

Use `-Q` to trade size for quality. `-Q 85` (default) is visually lossless for most content. `-Q 70` roughly halves the file size. Pass-through JPEGs (already correct colour, no rotation needed) are never re-encoded regardless of `-Q`.

---

## License

MIT — see [LICENSE](LICENSE).
