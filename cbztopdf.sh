#!/usr/bin/env bash
#
# cbztopdf.sh - convert CBZ comics to PDF, tuned for reading webtoons / manhwa
#
# Works in Termux and on Linux. Needs bash 4.4+, ImageMagick (6 or 7), unzip,
# and the usual coreutils/awk/find. See README.md for details.
#
# How it works:
#   1. Extract the CBZ and put the images in natural order (1, 2, ... 10).
#   2. Normal comics: one PDF page per image. JPEGs go in untouched.
#      Webtoons: strips are stitched into one long image and cut into pages
#      in the blank gaps between panels, so no panel is cut in half and no
#      single page is taller than PDF viewers can handle.
#   3. The PDF is written by this script (no ImageMagick PDF coder needed),
#      so memory use stays low and quality is not touched by a second encode.

set -u -o pipefail
export LC_NUMERIC=C

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "Error: bash 4.4 or newer is required (found $BASH_VERSION)." >&2
    exit 1
fi

VERSION="2.0.0"
SELF=${0##*/}

# --- Settings (see --help) ----------------------------------------------------
OUTPUT_DIR=""       # empty = write each PDF next to its source
FORCE=false
RECURSIVE=false
ALL=false
JOBS=1              # archives converted at once; each one is memory hungry
MAX_WIDTH=0         # 0 = keep original width
QUALITY=90          # JPEG quality for pages that have to be re-encoded
WEBTOON=auto        # auto | on | off
PAGE_RATIO=3        # webtoon page height = PAGE_RATIO x width
SMART_SPLIT=true    # cut webtoon pages in blank gaps
VERBOSE=false

# --- Tuning (webtoon mode) ----------------------------------------------------
AUTO_RATIO=2        # median height/width at or above this => webtoon
SLICE_RATIO=1.2     # ...or above this if the images look like slices of one strip
EDGE_SAMPLES=8      # images whose top and bottom edge are checked to tell slices from pages
EDGE_PERCENT=40     # webtoon if at least this share (%) of those edges touch artwork
PROFILE_COLS=64     # each row is shrunk to this many columns to test if it is blank
BLANK_TOL=10        # row is blank if its darkest and brightest column differ by <= this (0-255)
MIN_GAP=4           # prefer blank bands at least this many rows tall
GAP_MARGIN=16       # keep this much blank space on both sides of a cut
BACK=0.30           # a page may end up to 30% shorter than the target...
FWD=0.30            # ...or 30% taller, to land in a blank gap
TAIL=0.25           # never leave a last page shorter than this fraction of the target
MAX_PDF_DIM=14400   # many viewers refuse pages above 200 inch = 14400 pt

IM_CONVERT=()
IM_IDENTIFY=()
INPUTS=()
TARGETS=()
SUBDIRS=()          # per target: its folder below the current directory (for --recursive with --output-dir)
STATE_DIR=""
WORK_DIR=""
PART_FILE=""
LOG_PREFIX=""
IMG_COUNT=0
PAGES=0
MODE=pages

# --- Output helpers -----------------------------------------------------------
say()  { printf '%s%s\n' "$LOG_PREFIX" "$*"; }
note() { if $VERBOSE; then printf '%s  %s\n' "$LOG_PREFIX" "$*"; fi; }
warn() { printf '%sWarning: %s\n' "$LOG_PREFIX" "$*" >&2; }
err()  { printf '%sError: %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { err "$*"; exit 1; }

progress() {   # label done total - single updating line, only on a terminal
    if [ -t 2 ] && ! $VERBOSE && [ "$JOBS" -le 1 ]; then
        printf '\r\033[K  %s %d/%d' "$1" "$2" "$3" >&2
        if [ "$2" -ge "$3" ]; then printf '\r\033[K' >&2; fi
    fi
}

plural()  { if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }   # 1 page, 2 pages

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
is_num()  { [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; }
fge()     { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }   # a >= b (decimals)

human_size() {   # bytes -> "12.3 MB"
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) printf "%.1f MB", b / 1048576
        else printf "%.0f KB", b / 1024 }'
}

show_help() {
    cat <<EOF
Usage: $SELF [options] [FILE.cbz | FOLDER ...]

Convert CBZ comics to PDF. With no FILE given, every .cbz in the current
directory is converted. Webtoon / manhwa strips are detected automatically,
stitched together and cut into pages in the blank gaps between panels.

Input
  FILE.cbz              Archive to convert (any number of them).
  FOLDER                Convert a folder of images instead of an archive.
  -a, --all             Convert every .cbz in the current directory
                        (this is the default when no FILE is given).
  -R, --recursive       With --all, also look in sub-directories.
  -f, --file FILE       Same as passing FILE.

Output
  -o, --output-dir DIR  Write the PDFs to DIR (default: next to each source).
      --force           Overwrite PDFs that already exist (default: skip).

Webtoon / manhwa
      --webtoon         Always stitch and re-slice.
      --no-webtoon      Always use one PDF page per image.
                        (default: detect from the image shapes)
      --page-ratio R    Page height as a multiple of the width (default $PAGE_RATIO).
                        Bigger = fewer page breaks, heavier pages.
      --hard-cut        Cut at exact positions instead of in blank gaps.

Size and speed
  -w, --width N         Shrink pages wider than N pixels (never enlarges).
  -Q, --quality N       JPEG quality 1-100 for re-encoded pages (default $QUALITY).
                        JPEGs that need no change are embedded as they are.
  -j, --jobs N          Convert N archives at the same time (default $JOBS).

  -v, --verbose         Show more detail.
  -h, --help            Show this help.
      --version         Show the version.

Examples
  $SELF                                  Convert every .cbz in this folder
  $SELF "Chapter 12.cbz"                 Convert one file
  $SELF -R -o ~/pdfs                     Everything below here, PDFs into ~/pdfs
  $SELF --webtoon -w 1080 ch*.cbz        Force webtoon mode, 1080 px wide pages
EOF
}

# --- Dependencies -------------------------------------------------------------
check_dependencies() {
    if command -v magick >/dev/null 2>&1; then
        IM_CONVERT=(magick)
        IM_IDENTIFY=(magick identify)
    elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
        IM_CONVERT=(convert)
        IM_IDENTIFY=(identify)
    else
        die "ImageMagick is not installed. Install it with 'pkg install imagemagick' (Termux) or 'sudo apt install imagemagick'."
    fi
    local tool
    for tool in unzip awk od sort find xargs wc mktemp; do
        command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. Install it with 'pkg install $tool' (Termux) or your package manager."
    done
}

# --- Minimal PDF writer -------------------------------------------------------
# Every page is one JPEG stored as-is (DCTDecode). Object numbers are fixed:
# 1 catalog, 2 page tree, 3 info, then for page n: 3n+1 image, 3n+2 content, 3n+3 page.
PDF_FILE=""
PDF_TITLE=""
PDF_COUNT=0
PDF_KIDS=""
declare -a PDF_OFF=()

pdf_begin() {   # file title
    PDF_FILE=$1
    PDF_TITLE=$2
    PDF_COUNT=0
    PDF_KIDS=""
    PDF_OFF=()
    printf '%%PDF-1.4\n%%\342\343\317\323\n' > "$PDF_FILE"
}

pdf_mark() {   # remember where object $1 starts
    local size
    size=$(wc -c < "$PDF_FILE")
    PDF_OFF[$1]=$((size))
}

pdf_text() {   # PDF text string for $1: plain ASCII, or UTF-16BE hex for anything else
    printf '%s' "$1" | od -An -v -tu1 | LC_ALL=C awk '
        { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
        END {
            ascii = 1
            for (i = 0; i < n; i++) if (b[i] < 32 || b[i] > 126) ascii = 0
            if (ascii) {
                s = "("
                for (i = 0; i < n; i++) {
                    c = b[i]
                    if (c == 40 || c == 41 || c == 92) s = s "\\"
                    s = s sprintf("%c", c)
                }
                print s ")"
                exit
            }
            s = "<FEFF"
            i = 0
            while (i < n) {
                c = b[i]
                if (c < 128)       { cp = c; k = 1 }
                else if (c >= 240) { cp = (c - 240) * 262144 + (b[i+1] - 128) * 4096 + (b[i+2] - 128) * 64 + (b[i+3] - 128); k = 4 }
                else if (c >= 224) { cp = (c - 224) * 4096 + (b[i+1] - 128) * 64 + (b[i+2] - 128); k = 3 }
                else if (c >= 192) { cp = (c - 192) * 64 + (b[i+1] - 128); k = 2 }
                else               { cp = 63; k = 1 }
                i += k
                if (cp > 65535) { cp -= 65536; s = s sprintf("%04X%04X", 55296 + int(cp / 1024), 56320 + cp % 1024) }
                else s = s sprintf("%04X", cp)
            }
            print s ">"
        }'
}

pdf_add_jpeg() {   # jpeg-file width height colorspace(sRGB|Gray)
    local jpg=$1 w=$2 h=$3 cs=$4
    local bw=$w bh=$h space=/DeviceRGB len img cnt page content
    PDF_COUNT=$((PDF_COUNT + 1))
    img=$((3 * PDF_COUNT + 1)); cnt=$((img + 1)); page=$((img + 2))
    if [ "$cs" = Gray ]; then space=/DeviceGray; fi
    if [ "$w" -gt "$MAX_PDF_DIM" ] || [ "$h" -gt "$MAX_PDF_DIM" ]; then   # keep the page box within what viewers accept
        read -r bw bh < <(awk -v w="$w" -v h="$h" -v m="$MAX_PDF_DIM" 'BEGIN {
            s = (w > h ? w : h); s = m / s; printf "%.2f %.2f\n", w * s, h * s }')
    fi
    len=$(wc -c < "$jpg"); len=$((len))

    pdf_mark "$img"
    printf '%d 0 obj\n<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n' \
        "$img" "$w" "$h" "$space" "$len" >> "$PDF_FILE"
    cat "$jpg" >> "$PDF_FILE"
    printf '\nendstream\nendobj\n' >> "$PDF_FILE"

    content="q $bw 0 0 $bh 0 0 cm /Im0 Do Q"
    pdf_mark "$cnt"
    printf '%d 0 obj\n<< /Length %d >>\nstream\n%s\nendstream\nendobj\n' "$cnt" "${#content}" "$content" >> "$PDF_FILE"

    pdf_mark "$page"
    printf '%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources << /XObject << /Im0 %d 0 R >> >> /Contents %d 0 R >>\nendobj\n' \
        "$page" "$bw" "$bh" "$img" "$cnt" >> "$PDF_FILE"
    PDF_KIDS+="$page 0 R "
}

pdf_finish() {
    local total xref i
    pdf_mark 1
    printf '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /PageLayout /OneColumn /OpenAction [6 0 R /FitH null] >>\nendobj\n' >> "$PDF_FILE"
    pdf_mark 2
    printf '2 0 obj\n<< /Type /Pages /Count %d /Kids [%s] >>\nendobj\n' "$PDF_COUNT" "${PDF_KIDS% }" >> "$PDF_FILE"
    pdf_mark 3
    printf '3 0 obj\n<< /Title %s /Producer (cbztopdf.sh %s) /CreationDate (D:%sZ) >>\nendobj\n' \
        "$(pdf_text "$PDF_TITLE")" "$VERSION" "$(date -u +%Y%m%d%H%M%S)" >> "$PDF_FILE"

    xref=$(wc -c < "$PDF_FILE"); xref=$((xref))
    total=$((3 * PDF_COUNT + 4))
    {
        printf 'xref\n0 %d\n0000000000 65535 f \n' "$total"
        for ((i = 1; i < total; i++)); do
            printf '%010d 00000 n \n' "${PDF_OFF[$i]}"
        done
        printf 'trailer\n<< /Size %d /Root 1 0 R /Info 3 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$total" "$xref"
    } >> "$PDF_FILE"
}

# --- Finding and preparing the images ----------------------------------------
# NUL-separated list of the images below $1 in natural order (2 before 10).
# macOS leftovers (__MACOSX, ._name) are skipped; they look like images but are not.
list_images() {
    find "$1" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.jfif' -o -iname '*.png' -o -iname '*.gif' \
           -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' \) \
        ! -path '*/__MACOSX/*' ! -name '._*' -print0 | LC_ALL=C sort -zV
}

# Put numbered links to every image of $1 (archive or folder) into $2/img.
# Short plain names mean odd file names (spaces, brackets, colons) can never confuse ImageMagick.
stage_images() {
    local src=$1 work=$2 root rc f ext name n=0
    mkdir -p "$work/img" || return 1
    if [ -d "$src" ]; then
        root=$(cd "$src" && pwd) || return 1
    else
        root=$work/extracted
        mkdir -p "$root" || return 1
        case $src in /*) ;; *) src=./$src ;; esac
        unzip -qq -o "$src" -d "$root" >/dev/null 2>"$work/unzip.log"
        rc=$?
        if [ "$rc" -gt 1 ]; then   # 1 only means "warnings"
            if [ "$(head -c 4 "$src" 2>/dev/null | tr -d '\000')" = "Rar!" ]; then
                err "'$src' is a RAR archive (.cbr). Only ZIP based .cbz files are supported."
                return 1
            fi
            warn "'$src' is damaged or not a ZIP archive (unzip exit code $rc); using whatever could be extracted."
        fi
    fi
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        ext=${f##*.}
        printf -v name '%05d.%s' "$n" "${ext,,}"
        ln -s "$f" "$work/img/$name" || return 1
    done < <(list_images "$root")
    IMG_COUNT=$n
    if [ "$n" -eq 0 ]; then
        err "no images found in '$src'."
        return 1
    fi
}

# info.tsv: name, width, height, format, colorspace, needs-rotation (EXIF) - one line per readable image.
# Width and height are already swapped for sideways images.
gather_info() {
    local work=$1 readable
    # ImageMagick does not expand \t in -format (it prints a plain "t"), so fields are split on "|".
    ( cd "$work" && printf '%s\0' img/* \
        | xargs -0 "${IM_IDENTIFY[@]}" -ping -format '%f|%w|%h|%m|%[colorspace]|%[orientation]\n' 2>"$work/identify.log" ) \
    | awk -F'|' 'BEGIN { OFS = "\t" }
        NF == 6 && !seen[$1]++ {
            o = $6; rot = (o != "Undefined" && o != "TopLeft" && o != "") ? 1 : 0
            w = $2; h = $3
            if (o == "LeftTop" || o == "RightTop" || o == "RightBottom" || o == "LeftBottom") { t = w; w = h; h = t }
            print $1, w, h, toupper($4), $5, rot
        }' > "$work/info.tsv"
    readable=$(wc -l < "$work/info.tsv"); readable=$((readable))
    if [ "$readable" -eq 0 ]; then
        err "ImageMagick could not read any of the $IMG_COUNT images."
        head -n 2 "$work/identify.log" >&2
        err "This is often ImageMagick's security policy (policy.xml); see 'Troubleshooting' in the README."
        return 1
    fi
    if [ "$readable" -lt "$IMG_COUNT" ]; then
        warn "$((IMG_COUNT - readable)) of $IMG_COUNT files could not be read by ImageMagick and are left out."
        note "first problem: $(head -n 1 "$work/identify.log")"
    fi
}

# --- Webtoon or normal comic? ---------------------------------------------------
# A webtoon that was cut into slices is hard to tell from manga by shape alone. The edges tell:
# a slice is cut through the artwork, a manga page has a blank margin. Looks at a few images
# and prints the share (0-100) of top/bottom edges that touch artwork.
edge_contact() {
    local work=$1 name w v touching=0 total=0
    while IFS=$'\t' read -r name w; do
        # the top and the bottom row of the image, each squeezed to PROFILE_COLS pixels, as two rows of raw grey
        v=$("${IM_CONVERT[@]}" -background white "$work/img/${name}[0]" -auto-orient -alpha remove -alpha off -colorspace Gray \
                '(' +clone -gravity North -crop "${w}x1+0+0" +repage -scale "${PROFILE_COLS}x1!" ')' \
                '(' -clone 0 -gravity South -crop "${w}x1+0+0" +repage -scale "${PROFILE_COLS}x1!" ')' \
                -delete 0 -append -depth 8 gray:- 2>/dev/null \
            | od -An -v -tu1 -w"$PROFILE_COLS" \
            | awk '{ lo = 255; hi = 0; for (i = 1; i <= NF; i++) { if ($i + 0 < lo) lo = $i + 0; if ($i + 0 > hi) hi = $i + 0 } print hi - lo }')
        while IFS= read -r spread; do
            [ -n "$spread" ] || continue
            total=$((total + 1))
            if [ "$spread" -gt "$BLANK_TOL" ]; then touching=$((touching + 1)); fi
        done <<< "$v"
    done < <(awk -F'\t' -v k="$EDGE_SAMPLES" '{ n[NR] = $1; w[NR] = $2 }
        END { if (NR <= k) { for (i = 1; i <= NR; i++) print n[i] "\t" w[i]; exit }
              for (i = 0; i < k; i++) { j = int(i * (NR - 1) / (k - 1)) + 1; print n[j] "\t" w[j] } }' "$work/info.tsv")
    if [ "$total" -eq 0 ]; then echo 0; else echo $((touching * 100 / total)); fi
}

# Can ImageMagick hand over raw pixels? Some policy.xml files forbid it, and webtoon mode needs it.
IM_RAW=""
im_raw_ok() {
    local n
    if [ -z "$IM_RAW" ]; then
        n=$("${IM_CONVERT[@]}" -size 4x2 xc:white -depth 8 gray:- 2>/dev/null | wc -c)
        if [ "$((n))" -eq 8 ]; then IM_RAW=yes; else IM_RAW=no; fi
    fi
    [ "$IM_RAW" = yes ]
}

decide_mode() {   # sets MODE to "webtoon" or "pages" (a global: this must not print, see note())
    local work=$1 median share touch
    MODE=pages
    case $WEBTOON in
        on)  MODE=webtoon; return ;;
        off) return ;;
    esac
    median=$(awk -F'\t' '$2 > 0 { printf "%.4f\n", $3 / $2 }' "$work/info.tsv" | sort -n \
             | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)]; else print 0 }')
    share=$(awk -F'\t' '{ c[$2]++; if (c[$2] > b) b = c[$2] } END { if (NR) printf "%.2f", b / NR; else print 0 }' "$work/info.tsv")
    if fge "$median" "$AUTO_RATIO"; then
        note "median height/width is $median: tall strips, so webtoon"
        MODE=webtoon
    elif fge "$median" "$SLICE_RATIO" && fge "$share" 0.8; then
        if ! im_raw_ok; then
            note "ImageMagick cannot output raw pixels (policy.xml), so no webtoon detection"
            return
        fi
        touch=$(edge_contact "$work")
        note "median height/width is $median and $touch% of the sampled image edges touch artwork"
        if [ "$touch" -ge "$EDGE_PERCENT" ]; then MODE=webtoon; fi
    else
        note "median height/width is $median: normal pages"
    fi
}

# --- Normal comics: one page per image -----------------------------------------
build_pages() {
    local work=$1 name w h fmt cs rot out resize n=0 total skipped=0
    total=$(wc -l < "$work/info.tsv"); total=$((total))
    say "  $(plural "$total" image), one PDF page per image"
    mkdir -p "$work/pg"
    : > "$work/pagelist"
    while IFS=$'\t' read -r name w h fmt cs rot; do
        n=$((n + 1))
        progress "Preparing pages" "$n" "$total"
        if [ "$fmt" = JPEG ] && [ "$rot" -eq 0 ] && { [ "$cs" = sRGB ] || [ "$cs" = Gray ]; } \
           && { [ "$MAX_WIDTH" -eq 0 ] || [ "$w" -le "$MAX_WIDTH" ]; }; then
            printf 'img/%s\0' "$name" >> "$work/pagelist"   # embed the original JPEG untouched
            continue
        fi
        out=pg/${name%.*}.jpg
        resize=()
        if [ "$MAX_WIDTH" -gt 0 ] && [ "$w" -gt "$MAX_WIDTH" ]; then resize=(-resize "${MAX_WIDTH}x>"); fi
        if "${IM_CONVERT[@]}" -background white "$work/img/${name}[0]" -auto-orient -alpha remove -alpha off \
              "${resize[@]}" -colorspace sRGB -strip -type TrueColor -interlace none -quality "$QUALITY" \
              "$work/$out" 2>>"$work/im.log"; then
            printf '%s\0' "$out" >> "$work/pagelist"
        else
            skipped=$((skipped + 1))
            warn "could not convert image $name (image number $n) and left it out."
            note "$(tail -n 1 "$work/im.log")"
        fi
    done < "$work/info.tsv"
    if [ "$skipped" -eq "$total" ]; then err "none of the images could be converted."; return 1; fi
}

# --- Webtoons: stitch, find blank gaps, cut into pages --------------------------
# Reads good.tsv (strip, name, width, height, scaled height) and profile.txt (one number per row of
# the stitched strip: how much that row varies; small = blank) and prints the plan, one line per
# piece: page, strip, offset in strip, rows.
read -r -d '' PLAN_AWK <<'AWK'
function choose(yt, lo, hi,    pass, minlen, k, a, b, len, m, l, h, c, d, best, bestd, bestlen, y, v, mn, mny) {
    if (!SMART) return int(yt + 0.5)
    for (pass = 1; pass <= 2; pass++) {
        minlen = (pass == 1) ? MINGAP : 1
        best = -1; bestd = 1e18; bestlen = 0
        for (k = 1; k <= nr; k++) {
            a = ra[k]; b = rb[k] + 1
            if (a > hi) break
            if (b < lo) continue
            len = b - a
            if (len < minlen) continue
            m = int(len / 2); if (m > MARGIN) m = MARGIN
            l = a + m; h = b - m
            if (l < lo) l = lo
            if (h > hi) h = hi
            if (l > h) continue
            c = yt; if (c < l) c = l; if (c > h) c = h
            d = (c > yt) ? c - yt : yt - c
            if (d < bestd || (d == bestd && len > bestlen)) { best = c; bestd = d; bestlen = len }
        }
        if (best >= 0) return best
    }
    # no blank gap in reach: cut where the picture is calmest
    mn = 1e9; mny = int(yt + 0.5)
    for (y = lo; y <= hi; y++) {
        v = blank[y + 1]
        if (v < mn || (v == mn && ((y > yt) ? y - yt : yt - y) < ((mny > yt) ? mny - yt : yt - mny))) { mn = v; mny = y }
    }
    return mny
}
function emit(p0, p1,    s, s0, s1, a, b) {
    pg++
    while (cur < ns && sstart[cur + 1] + sh[cur + 1] <= p0) cur++
    for (s = cur + 1; s <= ns; s++) {
        s0 = sstart[s]; s1 = s0 + sh[s]
        if (s0 >= p1) break
        a = (p0 > s0) ? p0 : s0
        b = (p1 < s1) ? p1 : s1
        if (b > a) print pg "\t" s "\t" (a - s0) "\t" (b - a)
    }
}
FNR == NR { ns++; sh[ns] = $5 + 0; sstart[ns] = total; total += sh[ns]; next }
{ blank[++nrows] = $1 + 0 }
END {
    if (nrows != total) { printf "profile has %d rows, strip is %d rows tall\n", nrows, total > "/dev/stderr"; exit 1 }
    inrun = 0
    for (y = 1; y <= nrows; y++) {
        if (blank[y] <= TOL) { if (!inrun) { inrun = 1; nr++; ra[nr] = y - 1 } rb[nr] = y - 1 }
        else inrun = 0
    }
    y0 = 0
    while (1) {
        if (total - y0 <= (1 + FWD) * T) { emit(y0, total); break }
        hi = y0 + (1 + FWD) * T
        if (hi > total - TAIL * T) hi = total - TAIL * T
        c = choose(y0 + T, int(y0 + (1 - BACK) * T + 0.5), int(hi))
        if (c <= y0) c = y0 + T
        emit(y0, c)
        y0 = c
    }
}
AWK

build_webtoon() {
    local work=$1 W T maxT n=0 total idx name sw sh scaled got pages
    if ! im_raw_ok; then
        err "this ImageMagick may not output raw pixel data (policy.xml), which webtoon mode needs."
        err "See 'Troubleshooting' in the README, or use --no-webtoon."
        return 1
    fi
    # page width: the most common width (never above --width)
    W=$(awk -F'\t' '{ c[$2]++ } END { for (w in c) if (c[w] > bc || (c[w] == bc && w + 0 > best)) { best = w + 0; bc = c[w] } print best }' "$work/info.tsv")
    if [ "$MAX_WIDTH" -gt 0 ] && [ "$W" -gt "$MAX_WIDTH" ]; then W=$MAX_WIDTH; fi
    if [ "$W" -gt "$MAX_PDF_DIM" ]; then W=$MAX_PDF_DIM; fi
    T=$(awk -v w="$W" -v r="$PAGE_RATIO" 'BEGIN { printf "%d", w * r + 0.5 }')
    maxT=$(awk -v m="$MAX_PDF_DIM" -v f="$FWD" 'BEGIN { printf "%d", m / (1 + f) }')
    if [ "$T" -gt "$maxT" ]; then
        warn "page height limited to $maxT px (PDF viewers do not handle taller pages)."
        T=$maxT
    fi
    if [ "$T" -lt 200 ]; then T=200; fi

    # strips.tsv: every image scaled to the page width
    awk -F'\t' -v W="$W" 'BEGIN { OFS = "\t" }
        { H = int($3 * W / $2 + 0.5); if (H < 1) H = 1; print NR, $1, $2, $3, H }' "$work/info.tsv" > "$work/strips.tsv"
    total=$(wc -l < "$work/strips.tsv"); total=$((total))

    : > "$work/good.tsv"; : > "$work/profile.txt"
    while IFS=$'\t' read -r idx name sw sh scaled; do
        n=$((n + 1))
        progress "Looking for panel gaps" "$n" "$total"
        if "${IM_CONVERT[@]}" -background white "$work/img/${name}[0]" -auto-orient -alpha remove -alpha off \
              -colorspace Gray -scale "${PROFILE_COLS}x${scaled}!" -depth 8 gray:- 2>>"$work/im.log" \
           | od -An -v -tu1 -w"$PROFILE_COLS" \
           | awk '{ lo = 255; hi = 0; for (i = 1; i <= NF; i++) { v = $i + 0; if (v < lo) lo = v; if (v > hi) hi = v } print hi - lo }' > "$work/row.tmp" \
           && got=$(wc -l < "$work/row.tmp") && [ "$((got))" -eq "$scaled" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$name" "$sw" "$sh" "$scaled" >> "$work/good.tsv"
            cat "$work/row.tmp" >> "$work/profile.txt"
        else
            warn "could not read image $n of $total and left it out."
            note "$(tail -n 1 "$work/im.log")"
        fi
    done < "$work/strips.tsv"
    if [ ! -s "$work/good.tsv" ]; then err "none of the images could be read."; return 1; fi

    awk -F'\t' -v T="$T" -v TOL="$BLANK_TOL" -v MINGAP="$MIN_GAP" -v MARGIN="$GAP_MARGIN" \
        -v BACK="$BACK" -v FWD="$FWD" -v TAIL="$TAIL" -v SMART="$($SMART_SPLIT && echo 1 || echo 0)" \
        "$PLAN_AWK" "$work/good.tsv" "$work/profile.txt" > "$work/plan.tsv" || { err "could not plan the pages."; return 1; }
    pages=$(awk -F'\t' 'END { print $1 + 0 }' "$work/plan.tsv")
    say "  $(plural "$total" image) -> webtoon mode: $(plural "$pages" page), ${W} px wide (about $T px tall)"

    render_webtoon_pages "$work" "$W" "$pages"
}

render_webtoon_pages() {
    local work=$1 W=$2 pages=$3 idx name sw sh scaled pg strip off len cur=0 out
    local -A s_name=() s_w=() s_h=()
    local -a args=()
    mkdir -p "$work/pg"
    : > "$work/pagelist"
    while IFS=$'\t' read -r idx name sw sh scaled; do
        s_name[$idx]=$name; s_w[$idx]=$sw; s_h[$idx]=$scaled
    done < "$work/good.tsv"

    flush_page() {
        printf -v out 'pg/%05d.jpg' "$cur"
        if ! "${IM_CONVERT[@]}" "${args[@]}" -append -strip -type TrueColor -interlace none -quality "$QUALITY" \
                "$work/$out" 2>>"$work/im.log"; then
            err "ImageMagick failed while building page $cur."
            tail -n 2 "$work/im.log" >&2
            return 1
        fi
        printf '%s\0' "$out" >> "$work/pagelist"
        progress "Building pages" "$cur" "$pages"
    }

    while IFS=$'\t' read -r pg strip off len; do
        if [ "$pg" -ne "$cur" ]; then
            if [ "$cur" -gt 0 ]; then flush_page || return 1; fi
            cur=$pg
            args=()
        fi
        args+=( '(' -background white "$work/img/${s_name[$strip]}[0]" -auto-orient -alpha remove -alpha off )   # [0] = first frame
        if [ "${s_w[$strip]}" -ne "$W" ]; then args+=( -resize "${W}x${s_h[$strip]}!" ); fi
        args+=( -crop "${W}x${len}+0+${off}" +repage -colorspace sRGB ')' )
    done < "$work/plan.tsv"
    flush_page || return 1
}

# --- Put the page JPEGs into a PDF ----------------------------------------------
assemble_pdf() {   # work-dir output-file title
    local work=$1 out=$2 title=$3 path w h fmt cs expected found=0
    expected=$(tr -cd '\000' < "$work/pagelist" | wc -c); expected=$((expected))
    # Ask ImageMagick what is really in the files we are about to embed.
    ( cd "$work" && xargs -0 "${IM_IDENTIFY[@]}" -ping -format '%i|%w|%h|%m|%[colorspace]\n' < pagelist 2>/dev/null ) > "$work/pages.txt"
    pdf_begin "$out" "$title"
    while IFS='|' read -r path w h fmt cs; do
        if [ "$fmt" != JPEG ] || { [ "$cs" != sRGB ] && [ "$cs" != Gray ]; }; then
            err "internal error: page file '$path' is $fmt/$cs, expected an RGB or grey JPEG."
            return 1
        fi
        pdf_add_jpeg "$work/$path" "$w" "$h" "$cs"
        found=$((found + 1))
    done < "$work/pages.txt"
    if [ "$found" -eq 0 ] || [ "$found" -ne "$expected" ]; then
        err "expected $expected pages but could read $found."
        return 1
    fi
    pdf_finish
    PAGES=$found
}

# --- One archive or folder -> one PDF --------------------------------------------
cleanup_worker() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
    if [ -n "$PART_FILE" ]; then rm -f "$PART_FILE"; fi
}

convert_one() {   # source index total [subdir]  ->  0 converted, 1 failed, 2 skipped
    local src=$1 idx=$2 total=$3 sub=${4:-} base outdir pdf size
    if [ -d "$src" ]; then
        src=$(cd -- "$src" && pwd) || { err "cannot open the folder '$1'."; return 1; }
        base=${src##*/}
    else
        base=${src##*/}; base=${base%.*}
    fi
    base=${base:-comic}
    outdir=$(dirname -- "$src")
    if [ -n "$OUTPUT_DIR" ]; then
        outdir=$OUTPUT_DIR
        # --recursive: keep the folder layout, so chapters with the same name in different series cannot collide
        if [ -n "$sub" ]; then outdir=$outdir/$sub; fi
    fi
    pdf=$outdir/$base.pdf

    if [ -e "$pdf" ] && ! $FORCE; then
        say "[$idx/$total] Skipping '$src': '$pdf' already exists (use --force to overwrite)."
        return 2
    fi
    say "[$idx/$total] $src"
    mkdir -p -- "$outdir" || { err "cannot create '$outdir'."; return 1; }
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cbztopdf.XXXXXX") || { err "cannot create a temporary directory."; return 1; }
    PART_FILE=$pdf.part

    stage_images "$src" "$WORK_DIR" || return 1
    gather_info "$WORK_DIR" || return 1
    decide_mode "$WORK_DIR"
    if [ "$MODE" = webtoon ]; then
        build_webtoon "$WORK_DIR" || return 1
    else
        build_pages "$WORK_DIR" || return 1
    fi
    assemble_pdf "$WORK_DIR" "$PART_FILE" "$base" || return 1
    mv -f -- "$PART_FILE" "$pdf" || { err "cannot write '$pdf'."; return 1; }
    PART_FILE=""
    size=$(wc -c < "$pdf"); size=$(human_size "$((size))")
    say "  Created '$pdf' ($(plural "$PAGES" page), $size)"
}

# --- Running the batch -----------------------------------------------------------
worker_entry() {   # runs in its own subshell: cleans up after itself, reports through STATE_DIR
    trap cleanup_worker EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$JOBS" -gt 1 ]; then LOG_PREFIX="[${1##*/}] "; fi
    local rc
    convert_one "$1" "$2" "$3" "${4:-}"
    rc=$?
    printf '%s\t%s\n' "$rc" "$1" >> "$STATE_DIR/results"
    exit 0
}

cleanup_main() {
    local pids
    pids=$(jobs -p 2>/dev/null)
    # shellcheck disable=SC2086  # word splitting of the PID list is intended
    if [ -n "$pids" ]; then kill $pids 2>/dev/null; fi
    if [ -n "$STATE_DIR" ]; then rm -rf "$STATE_DIR"; fi
}

parse_args() {
    local arg
    while [ $# -gt 0 ]; do
        arg=$1
        if [[ $arg == --*=* ]]; then   # --option=value  ->  --option value
            set -- "${arg%%=*}" "${arg#*=}" "${@:2}"
            arg=$1
        fi
        case $arg in
            -h|--help)       show_help; exit 0 ;;
            --version)       echo "$SELF $VERSION"; exit 0 ;;
            -a|--all)        ALL=true ;;
            -R|--recursive)  RECURSIVE=true ;;
            --force)         FORCE=true ;;
            --webtoon)       WEBTOON=on ;;
            --no-webtoon)    WEBTOON=off ;;
            --hard-cut)      SMART_SPLIT=false ;;
            -v|--verbose)    VERBOSE=true ;;
            -f|--file|-o|--output-dir|-j|--jobs|-w|--width|-Q|--quality|--page-ratio)
                [ $# -ge 2 ] || die "option '$arg' needs a value (see --help)."
                case $arg in
                    -f|--file)         INPUTS+=("$2") ;;
                    -o|--output-dir)   OUTPUT_DIR=$2 ;;
                    -j|--jobs)         JOBS=$2 ;;
                    -w|--width)        MAX_WIDTH=$2 ;;
                    -Q|--quality)      QUALITY=$2 ;;
                    --page-ratio)      PAGE_RATIO=$2 ;;
                esac
                shift ;;
            --)              shift; INPUTS+=("$@"); break ;;
            -?*)             die "unknown option '$arg' (see --help)." ;;
            *)               INPUTS+=("$arg") ;;
        esac
        shift
    done

    is_uint "$JOBS" && [ "$JOBS" -ge 1 ] || die "--jobs needs a whole number of 1 or more."
    is_uint "$MAX_WIDTH" || die "--width needs a whole number of pixels."
    is_uint "$QUALITY" && [ "$QUALITY" -ge 1 ] && [ "$QUALITY" -le 100 ] || die "--quality needs a number from 1 to 100."
    is_num "$PAGE_RATIO" && fge "$PAGE_RATIO" 0.5 || die "--page-ratio needs a number of 0.5 or more."
}

collect_targets() {
    local f key sub bad=0 depth=(-maxdepth 1)
    local -A seen=()
    if $RECURSIVE; then depth=(); fi
    for f in ${INPUTS[@]+"${INPUTS[@]}"}; do
        if [ -d "$f" ] || [ -f "$f" ]; then
            key=${f#./}
            if [ -z "${seen["$key"]:-}" ]; then   # the same file twice would make two workers write one PDF
                seen["$key"]=1
                TARGETS+=("$f")
                SUBDIRS+=("")
            fi
        else
            err "'$f' does not exist."
            bad=$((bad + 1))
        fi
    done
    if $ALL || [ ${#INPUTS[@]} -eq 0 ]; then
        while IFS= read -r -d '' f; do
            key=${f#./}
            if [ -n "${seen["$key"]:-}" ]; then continue; fi
            seen["$key"]=1
            TARGETS+=("$f")
            sub=$key
            case $sub in */*) sub=${sub%/*} ;; *) sub= ;; esac   # folder of the file, relative to here
            SUBDIRS+=("$sub")
        done < <(find . "${depth[@]}" -type f -iname '*.cbz' -print0 | LC_ALL=C sort -zV)
    fi
    return "$bad"
}

main() {
    parse_args "$@"
    check_dependencies

    local bad=0
    collect_targets || bad=$?
    if [ ${#TARGETS[@]} -eq 0 ]; then
        if [ "$bad" -eq 0 ]; then err "no CBZ files found in the current directory."; fi
        exit 1
    fi

    STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cbztopdf-run.XXXXXX") || die "cannot create a temporary directory."
    : > "$STATE_DIR/results"
    trap cleanup_main EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    local total=${#TARGETS[@]} i=0 running=0 t
    for t in "${TARGETS[@]}"; do
        i=$((i + 1))
        if [ "$JOBS" -le 1 ]; then
            ( worker_entry "$t" "$i" "$total" "${SUBDIRS[$((i - 1))]}" )
        else
            if [ "$running" -ge "$JOBS" ]; then
                wait -n 2>/dev/null || wait
                running=$((running - 1))
            fi
            ( worker_entry "$t" "$i" "$total" "${SUBDIRS[$((i - 1))]}" ) &
            running=$((running + 1))
        fi
    done
    wait

    local ok skipped failed
    ok=$(awk -F'\t' '$1 == 0' "$STATE_DIR/results" | wc -l)
    skipped=$(awk -F'\t' '$1 == 2' "$STATE_DIR/results" | wc -l)
    failed=$(awk -F'\t' '$1 != 0 && $1 != 2' "$STATE_DIR/results" | wc -l)
    failed=$((failed + bad))
    if [ "$total" -gt 1 ] || [ "$failed" -gt 0 ]; then
        echo "----------------------------------------"
        echo "Converted: $((ok))   Skipped (PDF exists): $((skipped))   Failed: $failed"
        echo "----------------------------------------"
    fi
    if [ "$failed" -gt 0 ]; then
        awk -F'\t' '$1 != 0 && $1 != 2 { print "  failed: " $2 }' "$STATE_DIR/results"
        exit 1
    fi
    exit 0
}

main "$@"
