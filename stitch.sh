#!/usr/bin/env bash
# Hugin stitcher: copy inputs -> camX.jpg -> color correction via ImageMagick -> stitch
# Usage:
#   ./stitch_full.sh [--protect-lights] [--clip-thr=0.995] [--clip-pct=0.001] BASE.pto OUT_PREFIX [IMAGES_DIR]
# Env:
#   KEEP_TMP=1   # чтобы НЕ удалять временную папку (по умолчанию удаляем)

set -euo pipefail

# ---- deps ----
need() { command -v "$1" >/dev/null 2>&1 || { echo "Нет команды: $1"; exit 1; }; }
need hugin_executor
need awk
need grep
need sed
need find
need sort
need readlink

# ImageMagick v7 (magick) или v6 (convert)
IM=""
if command -v magick >/dev/null 2>&1; then IM="magick"
elif command -v convert >/dev/null 2>&1; then IM="convert"
else
  echo "Не найден ImageMagick (magick/convert). Установи: sudo apt install imagemagick"
  exit 1
fi

# ---- options ----
PROTECT_LIGHTS=0
CLIP_THR="0.995"   # >=99.5% яркости считаем почти клиппингом
CLIP_PCT="0.001"   # до 0.1% «почти клиппинга» считаем, что клиппинга нет

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protect-lights) PROTECT_LIGHTS=1; shift ;;
    --clip-thr=*)     CLIP_THR="${1#*=}"; shift ;;
    --clip-pct=*)     CLIP_PCT="${1#*=}"; shift ;;
    --) shift; break ;;
    -*)
      echo "Неизвестный флаг: $1"
      echo "Использование: $0 [--protect-lights] [--clip-thr=0.995] [--clip-pct=0.001] BASE.pto OUT_PREFIX [IMAGES_DIR]"
      exit 1
      ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- "${positional[@]}"

# ---- args ----
if [[ $# -lt 2 ]]; then
  echo "Использование: $0 [опции] BASE.pto OUT_PREFIX [IMAGES_DIR]"
  exit 1
fi

BASE_PTO="$1"; shift
OUT_PREFIX="${1// /_}"; shift
IMAGES_DIR="${1:-.}"

[[ -f "$BASE_PTO" ]]   || { echo "Не найден проект: $BASE_PTO"; exit 1; }
[[ -d "$IMAGES_DIR" ]] || { echo "Нет папки: $IMAGES_DIR"; exit 1; }

# ---- read image count from PTO ----
PTO_N_IMAGES=$(grep -E '^[[:space:]]*i[[:space:]]' "$BASE_PTO" | wc -l | tr -d ' ')
[[ "$PTO_N_IMAGES" -gt 0 ]] || { echo "В проекте не найдено изображений."; exit 1; }

echo "Проект:   $BASE_PTO"
echo "Префикс:  $OUT_PREFIX"
echo "Источник: $IMAGES_DIR"
echo "Камер:    $PTO_N_IMAGES"
echo "Опции:    protect_lights=$PROTECT_LIGHTS clip_thr=$CLIP_THR clip_pct=$CLIP_PCT"
echo "------------------------------"

# ---- temp workdir + cleanup ----
WORKDIR="$(mktemp -d -t hugin_full_XXXXXX)"
cleanup() {
  if [[ "${KEEP_TMP:-0}" == "1" ]]; then
    echo "⏭  KEEP_TMP=1 — временная папка сохранена: $WORKDIR"
  else
    rm -rf "$WORKDIR"
    echo "🧹 Временные файлы удалены."
  fi
}
trap cleanup EXIT

TMP_PTO="$WORKDIR/$(basename "${BASE_PTO%.pto}")__swap.pto"
cp -f "$BASE_PTO" "$TMP_PTO"

# ---- helper: pick one file for camX ----
find_cam_file() {
  local idx="$1" dir="$2"
  find "$dir" -maxdepth 1 -type f \
    \( -iregex ".*/cam${idx}[_-].*\.\(jpg\|jpeg\|png\|tif\|tiff\)" -o -iregex ".*/cam${idx}\.\(jpg\|jpeg\|png\|tif\|tiff\)" \) \
    | sort -V | head -n1
}

# ---- copy to WORKDIR as camX.jpg ----
declare -a COPIED
for idx in $(seq 1 "$PTO_N_IMAGES"); do
  src="$(find_cam_file "$idx" "$IMAGES_DIR" || true)"
  [[ -n "$src" ]] || { echo "Не найден файл для маски cam${idx}* в $IMAGES_DIR"; exit 1; }
  dst="$WORKDIR/cam${idx}.jpg"
  cp -f -- "$src" "$dst"
  COPIED[$idx]="$dst"
  echo "cam$idx -> $(basename "$src")  =>  $(basename "$dst")"
done

# ---- replace file paths in PTO (n"...") by order of i-lines ----
MAP_PATHS="$WORKDIR/paths.txt"; : > "$MAP_PATHS"
for idx in $(seq 1 "$PTO_N_IMAGES"); do
  printf '%s\n' "$(readlink -f "${COPIED[$idx]}")" >> "$MAP_PATHS"
done

awk -v map="$MAP_PATHS" '
  BEGIN{
    idx=0;
    while((getline line < map)>0){ imgs[++idx]=line }
    total=idx; idx=0
  }
  {
    if ($0 ~ /^[[:space:]]*i[[:space:]]/) {
      idx++
      gsub(/n"[^"]*"/, "n\"" imgs[idx] "\"")
      print
    } else print
  }
' "$TMP_PTO" > "$TMP_PTO.new" && mv "$TMP_PTO.new" "$TMP_PTO"

# ---- ImageMagick helpers ----
im_mean() { # $1 file, $2 channel R|G|B
  $IM "$1" -colorspace RGB -channel "$2" -separate -format "%[fx:mean]" info:
}

im_highlight_frac() { # $1 file, $2 threshold (0..1)
  local f="$1" thr="$2" thr_pct
  thr_pct=$(awk -v t="$thr" 'BEGIN{printf "%.3f%%", 100*t}')
  # доля пикселей с Luma >= thr
  $IM "$f" -colorspace RGB -colorspace gray -threshold "$thr_pct" -format "%[fx:mean]" info:
}

# ---- color metrics ----
declare -a MEAN_R MEAN_G MEAN_B LUMA HCLIP
for idx in $(seq 1 "$PTO_N_IMAGES"); do
  f="${COPIED[$idx]}"
  r=$(im_mean "$f" R)
  g=$(im_mean "$f" G)
  b=$(im_mean "$f" B)
  y=$(awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN{printf "%.10f", 0.2126*r + 0.7152*g + 0.0722*b}')
  c=$(im_highlight_frac "$f" "$CLIP_THR")
  MEAN_R[$idx]="$r"; MEAN_G[$idx]="$g"; MEAN_B[$idx]="$b"; LUMA[$idx]="$y"; HCLIP[$idx]="$c"
  printf "cam%-2d: Luma=%.5f, highlight>=%.1f%% : %.4f (доля)\n" "$idx" \
         "$y" "$(awk -v t="$CLIP_THR" 'BEGIN{print 100*t}')" "$c"
done

# target luma = median
Y_TARGET="$(
  printf "%s\n" "${LUMA[@]:1}" | LC_ALL=C sort -n | awk '
    {a[++n]=$1}
    END{
      if(n==0){print 0; exit}
      if(n%2){printf "%.10f", a[(n+1)/2]}
      else    {printf "%.10f", (a[n/2]+a[n/2+1])/2.0}
    }'
)"

# base median Eev from PTO to keep global tone
MED_EEV="$(
  awk '
    /^[[:space:]]*i[[:space:]]/ {
      if (match($0, /Eev[-0-9.+eE]+/)) {
        v=substr($0, RSTART+3, RLENGTH-3); a[++n]=v;
      }
    }
    END{
      if(n==0){print 0; exit}
      for(i=2;i<=n;i++){x=a[i];j=i-1; while(j&&a[j]>x){a[j+1]=a[j]; j--} a[j+1]=x}
      if(n%2) print a[(n+1)/2]; else print (a[n/2]+a[n/2+1])/2.0
    }
  ' "$TMP_PTO"
)"

echo "Целевая яркость (медиана): $Y_TARGET"
echo "Медиана исходного Eev:     $MED_EEV"

# build correction table
MAP_CC="$WORKDIR/color_map.tsv"; : > "$MAP_CC"
for idx in $(seq 1 "$PTO_N_IMAGES"); do
  r="${MEAN_R[$idx]}"; g="${MEAN_G[$idx]}"; b="${MEAN_B[$idx]}"; y="${LUMA[$idx]}"; h="${HCLIP[$idx]}"

  # защита от нулей
  awk -v r="$r" -v b="$b" 'BEGIN{ if(r<=0) exit 1; if(b<=0) exit 2; exit 0 }' || { r="1e-6"; b="1e-6"; }

  Er=$(awk -v g="$g" -v r="$r" 'BEGIN{printf "%.6f", (r>0)? g/r : 1.0}')
  Eb=$(awk -v g="$g" -v b="$b" 'BEGIN{printf "%.6f", (b>0)? g/b : 1.0}')
  dEV=$(awk -v yt="$Y_TARGET" -v yi="$y" 'BEGIN{ if(yi<=0) yi=1e-6; printf "%.6f", (log(yt/yi)/log(2)) }')

  # --- защита светов: не затемнять, если света не клиппятся ---
  if [[ "$PROTECT_LIGHTS" == "1" ]]; then
    if awk -v d="$dEV" -v hc="$h" -v cp="$CLIP_PCT" 'BEGIN{exit !(d<0 && hc<cp)}'; then
      printf "cam%-2d: protect-lights: dEV %.4f -> 0.0000 (highlight_frac=%.5f < %.5f)\n" \
             "$idx" "$dEV" "$h" "$CLIP_PCT"
      dEV="0.000000"
    fi
  fi

  Eev=$(awk -v base="$MED_EEV" -v dev="$dEV" 'BEGIN{printf "%.6f", base+dev}')
  printf "%d\t%.6f\t%.6f\t%.6f\n" "$idx" "$Er" "$Eb" "$Eev" >> "$MAP_CC"
done

# apply Er/Eb/Eev by i-line order
awk -v map="$MAP_CC" '
  BEGIN{
    while ((getline line < map) > 0) {
      split(line, f, "\t")
      er[++n]=f[2]; eb[n]=f[3]; ev[n]=f[4]
    }
    idx=0
  }
  {
    if ($0 ~ /^[[:space:]]*i[[:space:]]/) {
      idx++
      gsub(/Er[-0-9.+eE]+/, "Er" er[idx])
      gsub(/Eb[-0-9.+eE]+/, "Eb" eb[idx])
      if (match($0, /Eev[-0-9.+eE]+/))
        gsub(/Eev[-0-9.+eE]+/, "Eev" ev[idx])
      else
        sub(/n"/, "Eev" ev[idx] " " "n\"")
      print
    } else print
  }
' "$TMP_PTO" > "$TMP_PTO.new" && mv "$TMP_PTO.new" "$TMP_PTO"

# ---- stitch ----
echo "✂️  Старт прошивки панорамы..."
set -x
hugin_executor --prefix="$OUT_PREFIX" --stitching "$TMP_PTO"
set +x
echo "✅ Готово. Результаты: ${OUT_PREFIX}*"
echo "TMP: $WORKDIR"
