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
civitai_find () {  # $1 civitai model id  $2 exact filename to match  $3 dest
  # Resolves the file's download URL from the CivitAI API at runtime (no hardcoded
  # version/file ids that go stale), then downloads it with the token.
  local mid="$1" fname="$2" dest="$3"
  if [ -z "${CIVITAI_TOKEN:-}" ]; then
    echo "  !! CIVITAI_TOKEN not set — skipping $fname"; FAILS+=("$dest (no token)"); return 1; fi
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "  SKIP (exists): ${dest#$COMFY_ROOT/}"; return 0; fi
  echo "  RESOLVE (civitai model $mid): $fname"
  local durl
  durl=$(curl -sL --fail "https://civitai.com/api/v1/models/${mid}?token=${CIVITAI_TOKEN}" \
    | python -c "import sys,json;
d=json.load(sys.stdin); t='''$fname'''.lower(); u=''
for v in d.get('modelVersions',[]):
    for f in v.get('files',[]):
        if f.get('name','').lower()==t: u=f.get('downloadUrl','')
print(u)" 2>/dev/null)
  if [ -z "$durl" ]; then
    echo "  !! could not find '$fname' in CivitAI model $mid"; FAILS+=("$dest (not found in model $mid)"); return 1; fi
  local sep="?"; [[ "$durl" == *"?"* ]] && sep="&"
  if ! curl -L --fail -C - -o "$dest" "${durl}${sep}token=${CIVITAI_TOKEN}"; then
    echo "  !! FAILED: ${dest#$COMFY_ROOT/}"; rm -f "$dest"; FAILS+=("$dest"); fi
}
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
  # Pose/tag picker (AnimaAdvancedV10_PosePicker.json alternate): PromptSwitch + WAS Text List nodes
  clone https://github.com/Boba-svg/ComfyUI-PromptSwitch
  clone https://github.com/WASasquatch/was-node-suite-comfyui
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

  say "LoRA (CivitAI — need CIVITAI_TOKEN)"
  civitai_lora 2959007 2838381   # urn:air:anima:lora:civitai:1252497@2959007+2838381
  civitai_lora 3191697 3072447   # urn:air:anima:lora:civitai:2828738@3191697+3072447
  civitai_lora 3062688 2941284   # urn:air:anima:lora:civitai:2724933@3062688+2941284
  civitai_lora 3202009 3083294   # urn:air:anima:lora:civitai:1979448@3202009+3083294
  civitai_lora 3184772 3065310   # bold enhancer | urn:air:anima:lora:civitai:2823195@3184772+3065310
  civitai_lora 3188441 3069074   # urn:air:anima:lora:civitai:2826118@3188441+3069074

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

  say "ControlNet-LLLite (HuggingFace, Comfy-Org)"
  fetch "https://huggingface.co/Comfy-Org/Anima-LLLite/resolve/main/model_patches/anima-lllite-any-test-like-v2.safetensors" \
        "$COMFY_ROOT/models/model_patches/anima-lllite-any-test-like-v2.safetensors"

  say "Eye detector + anime segmentation (CivitAI — need CIVITAI_TOKEN)"
  # Eyeful v2 (robust eye detection) — CivitAI model 178518
  civitai_find 178518 "Eyeful_v2-Individual.pt" \
        "$COMFY_ROOT/models/ultralytics/bbox/Eyeful_v2-Individual.pt"
  # anime nsfw detection / adetailer all-in-one — CivitAI model 1313556
  civitai_find 1313556 "ntd11_anime_nsfw_segm_v5-variant1.pt" \
        "$COMFY_ROOT/models/ultralytics/segm/ntd11_anime_nsfw_segm_v5-variant1.pt"
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
