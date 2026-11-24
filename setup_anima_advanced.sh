#!/usr/bin/env bash
# ============================================================================
#  AnimaAdvancedV10 workflow — FRESH-BOX ONE-SHOT SETUP (no persistent volume)
#  Base: Anima v1.0 (anima_baseV10) + Qwen encoder/VAE
#  Adds: face/hand/eye detailing (Impact), ControlNet-LLLite, Ultimate SD Upscale,
#        SAM 3.1 + SAM ViT-B, Remacri upscaler.
#
#  Run on a fresh Vast ComfyUI-template instance (via PROVISIONING_SCRIPT, or by hand).
#  Idempotent: present files are skipped; a re-run resumes.
#
#  SET ON THE BOX (never hard-code):
#    export COMFY_ROOT=/workspace/ComfyUI
#    export CIVITAI_TOKEN=xxxx        # for the CivitAI detector pack (see bottom)
#    export HF_TOKEN=hf_xxx           # optional, faster/resumable HF
#
#  USAGE: bash setup_anima_advanced.sh [all|nodes|models]
# ============================================================================
set -uo pipefail
COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
WHAT="${1:-all}"
HF_AUTH=(); [ -n "${HF_TOKEN:-}" ] && HF_AUTH=(--header "Authorization: Bearer ${HF_TOKEN}")
FAILS=()
say(){ echo -e "\n=== $* ==="; }

fetch () {  # $1 url  $2 dest
  local url="$1" dest="$2"; mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "  SKIP (exists): ${dest#$COMFY_ROOT/}"; return 0; fi
  echo "  GET: ${dest#$COMFY_ROOT/}"
  if ! curl -L --fail -C - "${HF_AUTH[@]}" -o "$dest" "$url"; then
    echo "  !! FAILED: ${dest#$COMFY_ROOT/}"; rm -f "$dest"; FAILS+=("$dest"); fi
}
civitai () {  # $1 civitai download url  $2 dest
  local url="$1" dest="$2"
  if [ -z "${CIVITAI_TOKEN:-}" ]; then
    echo "  !! CIVITAI_TOKEN not set — skipping ${dest#$COMFY_ROOT/}"; FAILS+=("$dest (no token)"); return 1; fi
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "  SKIP (exists): ${dest#$COMFY_ROOT/}"; return 0; fi
  local sep="?"; [[ "$url" == *"?"* ]] && sep="&"
  echo "  GET (civitai): ${dest#$COMFY_ROOT/}"
  if ! curl -L --fail -C - -o "$dest" "${url}${sep}token=${CIVITAI_TOKEN}"; then
    echo "  !! FAILED: ${dest#$COMFY_ROOT/}"; rm -f "$dest"; FAILS+=("$dest"); fi
}
clone () {  # $1 repo url
  local url="$1" name dir; name="$(basename "$url" .git)"; dir="$COMFY_ROOT/custom_nodes/$name"
  if [ -d "$dir" ]; then echo "  SKIP (exists): $name"; return 0; fi
  echo "  CLONE: $name"
  if git clone --depth 1 "$url" "$dir"; then
    [ -f "$dir/requirements.txt" ] && { pip install -r "$dir/requirements.txt" || { echo "  !! reqs failed: $name"; FAILS+=("deps: $name"); }; }
    [ -f "$dir/install.py" ] && ( cd "$dir" && python install.py ) || true
  else echo "  !! clone failed: $url"; FAILS+=("node: $url"); fi
}

install_nodes () {
  say "Custom nodes (exact set from the workflow's declared sources)"
  mkdir -p "$COMFY_ROOT/custom_nodes"
  echo "  Installing shared deps (opencv, etc.)"
  pip install opencv-python-headless numpy pillow scipy || echo "  !! shared deps hiccup"
  clone https://github.com/ltdrdata/ComfyUI-Manager
  clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts
  clone https://github.com/yolain/ComfyUI-Easy-Use
  clone https://github.com/alexopus/ComfyUI-Image-Saver
  clone https://github.com/ltdrdata/ComfyUI-Impact-Pack
  clone https://github.com/ltdrdata/ComfyUI-Impact-Subpack
  clone https://github.com/kijai/ComfyUI-KJNodes
  clone https://github.com/willmiao/ComfyUI-Lora-Manager
  clone https://github.com/pamparamm/ComfyUI-ppm
  clone https://github.com/Fannovel16/comfyui_controlnet_aux
  clone https://github.com/rgthree/rgthree-comfy
  clone https://github.com/ssitu/ComfyUI_UltimateSDUpscale
  # NOTE: the workflow also references RTXVideoSuperResolution (NVIDIA RTX-desktop /
  # Windows DLSS). It does NOT run on a Linux cloud GPU, so it's intentionally skipped.
  echo "  (Anything still missing: ComfyUI-Manager -> Install Missing Custom Nodes.)"
}

install_models () {
  say "Base model — Anima v1.0 + Qwen encoder/VAE (HuggingFace)"
  # workflow loads it as anima_baseV10.safetensors; HF ships it as anima-preview.safetensors -> rename
  fetch "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/diffusion_models/anima-preview.safetensors" \
        "$COMFY_ROOT/models/diffusion_models/anima_baseV10.safetensors"
  fetch "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors" \
        "$COMFY_ROOT/models/text_encoders/qwen_3_06b_base.safetensors"
  fetch "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
        "$COMFY_ROOT/models/vae/qwen_image_vae.safetensors"

  say "SAM models"
  fetch "https://huggingface.co/Comfy-Org/sam3.1/resolve/main/checkpoints/sam3.1_multiplex_fp16.safetensors" \
        "$COMFY_ROOT/models/checkpoints/sam3.1_multiplex_fp16.safetensors"
  fetch "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" \
        "$COMFY_ROOT/models/sams/sam_vit_b_01ec64.pth"

  say "Upscaler — Remacri"
  fetch "https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth" \
        "$COMFY_ROOT/models/upscale_models/4x_foolhardy_Remacri.pth"

  say "Detectors — face/hand (Bingsu adetailer)"
  fetch "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt" \
        "$COMFY_ROOT/models/ultralytics/bbox/face_yolov9c.pt"
  fetch "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt" \
        "$COMFY_ROOT/models/ultralytics/bbox/hand_yolov9c.pt"

  say "=== 3 NICHE MODELS — source not auto-confirmed (see notes at end) ==="
  # Eye detector + anime-nsfw segmentation: from CivitAI 'anime nsfw detection / adetailer
  # all-in-one' (model 1313556). Needs the exact file-download URLs + CIVITAI_TOKEN.
  # Uncomment and fill the <versionId>/<fileId> once confirmed:
  # civitai "https://civitai.com/api/download/models/<versionId>?fileId=<fileId>" \
  #         "$COMFY_ROOT/models/ultralytics/bbox/Eyeful_v2-Individual.pt"
  # civitai "https://civitai.com/api/download/models/<versionId>?fileId=<fileId>" \
  #         "$COMFY_ROOT/models/ultralytics/segm/ntd11_anime_nsfw_segm_v5-variant1.pt"
  # ControlNet-LLLite for Anima (loaded via ModelPatchLoader -> models/model_patches/):
  # fetch "<confirmed HF url>" \
  #       "$COMFY_ROOT/models/model_patches/anima-lllite-any-test-like-v2.safetensors"
  echo "  (left unfetched: Eyeful_v2-Individual.pt, ntd11_anime_nsfw_segm_v5-variant1.pt,"
  echo "   anima-lllite-any-test-like-v2.safetensors — fill sources in this script, then re-run)"
}

echo "ComfyUI root : $COMFY_ROOT"
echo "CivitAI token: $([ -n "${CIVITAI_TOKEN:-}" ] && echo set || echo 'NOT set')"
echo "HF token     : $([ -n "${HF_TOKEN:-}" ] && echo set || echo 'NOT set')"
case "$WHAT" in
  nodes)  install_nodes ;;
  models) install_models ;;
  all)    install_nodes; install_models ;;
  *) echo "usage: bash setup_anima_advanced.sh [all|nodes|models]"; exit 2 ;;
esac

if command -v supervisorctl >/dev/null 2>&1 && [ "$WHAT" != "models" ]; then
  say "Restarting ComfyUI"; supervisorctl restart comfyui || echo "  (restart via Instance Portal if needed)"
fi
echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  say "${#FAILS[@]} item(s) need attention"; for f in "${FAILS[@]}"; do echo "  - ${f#$COMFY_ROOT/}"; done
fi
say "Done. Load AnimaAdvancedV10.json in ComfyUI."
