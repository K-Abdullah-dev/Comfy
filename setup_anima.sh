#!/usr/bin/env bash
# ============================================================================
#  Aaalice Anima workflow — FRESH-BOX ONE-SHOT SETUP (no persistent volume)
#  Base models: SilvermoonMix Anima Turbo  +  MiaoMiao Harem (Anima)
#  Features:    SeedVR2 upscale + Face refine + Interrogation.  No Flux inpaint.
#
#  Run this on a brand-new rented instance. When it finishes, every model and
#  custom node is in place; restart/start ComfyUI and load workflow_english.json.
#  There is NO skip-across-instances benefit without a volume — a fresh box
#  re-downloads everything. (Within one box, a re-run resumes/skips.)
#
#  SET THESE ON THE BOX (never hard-coded in the file):
#    export COMFY_ROOT=/workspace/ComfyUI       # your ComfyUI dir
#    export CIVITAI_TOKEN=xxxxxxxx              # CivitAI API key (for the 2 base models)
#    export HF_TOKEN=hf_xxx                     # optional, faster/resumable HF
#
#  USAGE:
#    bash setup_anima.sh            # nodes + models, then restarts ComfyUI
#    bash setup_anima.sh nodes      # custom nodes only
#    bash setup_anima.sh models     # models only
# ============================================================================
set -uo pipefail

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
WHAT="${1:-all}"
HF_AUTH=();  [ -n "${HF_TOKEN:-}" ]     && HF_AUTH=(--header "Authorization: Bearer ${HF_TOKEN}")
FAILS=()
say(){ echo -e "\n=== $* ==="; }

# ---- generic HF / direct fetch: skip if present, resume, hard-fail clean ----
fetch () {
  local url="$1" dest="$2"; mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "  SKIP (exists): ${dest#$COMFY_ROOT/}"; return 0; fi
  echo "  GET: ${dest#$COMFY_ROOT/}"
  if ! curl -L --fail -C - "${HF_AUTH[@]}" -o "$dest" "$url"; then
    echo "  !! FAILED: ${dest#$COMFY_ROOT/}"; rm -f "$dest"; FAILS+=("$dest")
  fi
}

# ---- CivitAI fetch: requires $CIVITAI_TOKEN, appended as ?token= at runtime --
civitai () {   # $1 = civitai download URL (may already have ?fileId=...)  $2 = dest
  local url="$1" dest="$2"
  if [ -z "${CIVITAI_TOKEN:-}" ]; then
    echo "  !! CIVITAI_TOKEN not set — cannot fetch ${dest#$COMFY_ROOT/}"
    echo "     export CIVITAI_TOKEN=... (CivitAI -> Account -> API Keys) and re-run."
    FAILS+=("$dest (no token)"); return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "  SKIP (exists): ${dest#$COMFY_ROOT/}"; return 0; fi
  # choose ? or & depending on whether the URL already has a query string
  local sep="?"; [[ "$url" == *"?"* ]] && sep="&"
  echo "  GET (civitai): ${dest#$COMFY_ROOT/}"
  if ! curl -L --fail -C - -o "$dest" "${url}${sep}token=${CIVITAI_TOKEN}"; then
    echo "  !! FAILED: ${dest#$COMFY_ROOT/}"; rm -f "$dest"; FAILS+=("$dest")
  fi
}

# --------------------------------------------------------------- custom nodes
civitai_lora () {  # $1 version_id  $2 file_id  -> models/loras/ with the real filename
  local vid="$1" fid="$2" dir="$COMFY_ROOT/models/loras"
  if [ -z "${CIVITAI_TOKEN:-}" ]; then
    echo "  !! CIVITAI_TOKEN not set — skipping LoRA $vid"; FAILS+=("lora $vid (no token)"); return 1; fi
  mkdir -p "$dir"
  local info name
  info=$(curl -sL --fail "https://civitai.com/api/v1/model-versions/${vid}?token=${CIVITAI_TOKEN}")
  name=$(printf '%s' "$info" | python -c "import sys,json
d=json.load(sys.stdin); fid='$fid'
n=''
for f in d.get('files',[]):
    if str(f.get('id'))==fid: n=f.get('name','')
if not n and d.get('files'): n=d['files'][0].get('name','')
print(n)" 2>/dev/null)
  if [ -z "$name" ]; then echo "  !! couldn't resolve LoRA name (version $vid)"; FAILS+=("lora $vid (unresolved)"); return 1; fi
  local dest="$dir/$name"
  if [ -s "$dest" ]; then echo "  SKIP (exists): loras/$name"; return 0; fi
  echo "  GET (civitai lora): loras/$name"
  if ! curl -L --fail -C - -o "$dest" "https://civitai.com/api/download/models/${vid}?fileId=${fid}&token=${CIVITAI_TOKEN}"; then
    echo "  !! FAILED: loras/$name"; rm -f "$dest"; FAILS+=("$dest"); fi
}

clone () {
  local url="$1" name dir; name="$(basename "$url" .git)"; dir="$COMFY_ROOT/custom_nodes/$name"
  if [ -d "$dir" ]; then echo "  SKIP (exists): $name"; return 0; fi
  echo "  CLONE: $name"
  if git clone --depth 1 "$url" "$dir"; then
    # install this node's Python deps (visible failures, not swallowed)
    if [ -f "$dir/requirements.txt" ]; then
      pip install -r "$dir/requirements.txt" || { echo "  !! requirements failed: $name"; FAILS+=("deps: $name"); }
    fi
    # some nodes (e.g. Impact Pack) ship an install.py that must run
    if [ -f "$dir/install.py" ]; then
      ( cd "$dir" && python install.py ) || echo "  (install.py returned nonzero for $name — usually fine)"
    fi
  else echo "  !! clone failed: $url"; FAILS+=("node: $url"); fi
}

install_nodes () {
  say "Custom nodes"
  mkdir -p "$COMFY_ROOT/custom_nodes"
  # Common deps several nodes need but don't always pull in themselves.
  # opencv-python-headless = OpenCV (cv2) without GUI libs — required by Impact Pack,
  # and -headless avoids the libGL.so.1 error on a headless server.
  echo "  Installing shared deps (opencv, etc.)"
  pip install opencv-python-headless numpy pillow scipy || echo "  !! shared deps install hiccup"
  # --- exact pack list, derived from the workflow's declared node sources ---
  clone https://github.com/ltdrdata/ComfyUI-Manager            # GUI node/model manager
  clone https://github.com/Aaalice233/ComfyUI-Aaalice-Nodes    # PromptSelector, QuickGroupManager, BooruGallery (core of the workflow)
  clone https://github.com/Aaalice233/ComfyUI-Aaalice-Image-Picker  # AaaliceImagePicker
  clone https://github.com/yawiii/ComfyUI-Prompt-Assistant     # PromptExpand, ImageCaptionNode
  clone https://github.com/willmiao/ComfyUI-Lora-Manager       # Lora Loader (LoraManager) + trigger words
  clone https://github.com/LoganBooker/SesquiLSR               # SesquiLatentUpscale (dual-sampler base)
  clone https://github.com/harukimix/KreaSeedVarianceEnhancer  # KreaSeedVarianceEnhancer
  clone https://github.com/luxdelux7/ComfyUI-Forbidden-Vision  # face refine
  clone https://github.com/bedovyy/ComfyUI-WD-Timm-Tagger      # interrogation
  clone https://github.com/scraed/LanPaint                     # LanPaint sampler (multi-sampling inpaint)
  clone https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch  # InpaintCrop/Stitch
  clone https://github.com/ltdrdata/ComfyUI-Impact-Pack        # ImpactIfNone (needs cv2)
  clone https://github.com/kijai/ComfyUI-KJNodes               # SetNode/GetNode, ColorMatch, ModelPassThrough
  clone https://github.com/rgthree/rgthree-comfy               # Any Switch, Image Comparer
  # NOTE: the workflow also references nvidia-rtx-vsr-pro / storyAura/DLSS5-Comfyui
  # (the "NvidiaUpscale" group). Those are Windows + RTX-desktop DLSS nodes and do NOT
  # run on a Linux cloud GPU, so they are intentionally NOT installed. Leave that group
  # muted/bypassed in the workflow; everything else works without it.
  echo "  (Any still-missing node: open ComfyUI-Manager -> Install Missing Custom Nodes.)"
}

# -------------------------------------------------------------------- models
install_models () {
  say "Base models (CivitAI — need CIVITAI_TOKEN)"
  # MiaoMiao Harem (Anima) — your pinned file
  civitai "https://civitai.com/api/download/models/3248362?fileId=3131298" \
          "$COMFY_ROOT/models/diffusion_models/miaomiaoHaremAnima.safetensors"
  # SilvermoonMix Anima v2.3 2.9B Turbo (default base UNet)
  civitai "https://civitai.com/api/download/models/3335132" \
          "$COMFY_ROOT/models/diffusion_models/silvermoonmixAnima_v2329BTurbo.safetensors"

  say "LoRA (CivitAI — need CIVITAI_TOKEN)"
  civitai_lora 2959007 2838381   # urn:air:anima:lora:civitai:1252497@2959007+2838381
  civitai_lora 3191697 3072447   # urn:air:anima:lora:civitai:2828738@3191697+3072447
  civitai_lora 3062688 2941284   # urn:air:anima:lora:civitai:2724933@3062688+2941284

  say "Shared text encoder + VAE (HuggingFace)"
  fetch "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors" \
        "$COMFY_ROOT/models/text_encoders/qwen_3_06b_base.safetensors"
  fetch "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors" \
        "$COMFY_ROOT/models/vae/qwen_image_vae.safetensors"

  say "SeedVR2 upscale (HuggingFace)"
  fetch "https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/diffusion_models/seedvr2_7b_sharp_int8_convrot.safetensors" \
        "$COMFY_ROOT/models/diffusion_models/seedvr2_7b_sharp_int8_convrot.safetensors"
  fetch "https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/vae/seedvr2_ema_vae_fp16.safetensors" \
        "$COMFY_ROOT/models/vae/ema_vae_fp16.safetensors"   # loader expects this name

  say "Face refine — Forbidden Vision (HuggingFace, exact names)"
  for f in ForbiddenVision_face_detect_v1.pt \
           ForbiddenVision_face_segment_v1.safetensors \
           ForbiddenVision_neural_corrector_v1.safetensors; do
    fetch "https://huggingface.co/luxdelux7/ForbiddenVision_Models/resolve/main/$f" \
          "$COMFY_ROOT/models/forbidden_vision/$f"
  done

  say "Interrogation — WD Timm Tagger (HuggingFace, same subfolder)"
  TAG="$COMFY_ROOT/models/wd_taggers/pixai-tagger-v0.9-timm"
  for f in config.json model.safetensors selected_tags.csv; do
    fetch "https://huggingface.co/Bedovyy/pixai-tagger-v0.9-timm/resolve/main/$f" "$TAG/$f"
  done

  # The workflow's fallback / img2img LoadImage nodes reference an example image
  # (Aaalice_example.jpg) that isn't shipped. Without a file present those nodes
  # fail validation ("required media input has no file selected") and block Run,
  # even for plain txt2img. Drop in a neutral placeholder so they validate; the
  # user replaces it with a real image only when actually doing img2img.
  say "Placeholder input image (Aaalice_example.jpg)"
  mkdir -p "$COMFY_ROOT/input"
  if [ ! -s "$COMFY_ROOT/input/Aaalice_example.jpg" ]; then
    if python -c "from PIL import Image; Image.new('RGB',(832,1216),(127,127,127)).save('$COMFY_ROOT/input/Aaalice_example.jpg','JPEG')" 2>/dev/null; then
      echo "  placeholder ready"
    else
      echo "  (couldn't make placeholder; create input/Aaalice_example.jpg by hand if a LoadImage node complains)"
    fi
  else
    echo "  SKIP (exists)"
  fi
}

# -------------------------------------------------------------------- run
echo "ComfyUI root : $COMFY_ROOT"
echo "CivitAI token: $([ -n "${CIVITAI_TOKEN:-}" ] && echo set || echo 'NOT set')"
echo "HF token     : $([ -n "${HF_TOKEN:-}" ] && echo set || echo 'NOT set')"
case "$WHAT" in
  nodes)  install_nodes ;;
  models) install_models ;;
  all)    install_nodes; install_models ;;
  *) echo "usage: bash setup_anima.sh [all|nodes|models]"; exit 2 ;;
esac

# -------------------------------------------------------------------- summary
echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  say "${#FAILS[@]} item(s) FAILED — fix and re-run (done items are skipped)"
  for f in "${FAILS[@]}"; do echo "  - ${f#$COMFY_ROOT/}"; done
  exit 1
fi
say "All models + nodes in place. Nothing manual left."

# ----------------------------------------------------- restart ComfyUI (template)
# The Vast ComfyUI template runs ComfyUI under supervisor and started it at boot,
# BEFORE these custom nodes existed. It must be restarted to load them.
if command -v supervisorctl >/dev/null 2>&1 && [ "$WHAT" != "models" ]; then
  say "Restarting ComfyUI (supervisorctl restart comfyui)"
  supervisorctl restart comfyui || echo "  (could not restart via supervisor; restart it from the Instance Portal)"
else
  echo "Next: restart ComfyUI (Instance Portal -> restart comfyui, or: supervisorctl restart comfyui)"
fi
echo "Then open ComfyUI (port 8188) and load workflow_english.json."
