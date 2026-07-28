"""Full render: mask -> new backdrop -> contact shadow -> grade to reference.

Size-independent by design:
  * the product is found by difference-from-background + largest blob, with no
    assumption about where it is or how big it is;
  * every morphology kernel, feather radius and shadow dimension is derived
    from the DETECTED object size, not hardcoded pixels;
  * the shadow is anchored to the detected contact point (the object's lowest
    pixels), so tall and short products both sit on the surface correctly.
"""
from PIL import Image, ImageOps
import numpy as np
from scipy import ndimage
import json, sys, os

CFG = json.load(open(os.path.join(os.path.dirname(__file__), "preset.json")))
SRC, DST = sys.argv[1], sys.argv[2]

def odd(n):
    n = max(3, int(round(n)))
    return n + 1 - n % 2

# ---------------------------------------------------------------- load
# Honour the EXIF orientation tag. Phone cameras store the sensor buffer plus
# an orientation flag; every viewer applies it, so skipping this step silently
# rotates portrait photos by 90 degrees.
im = ImageOps.exif_transpose(Image.open(SRC)).convert("RGB")
PROC_W = CFG["processing_width"]
# Scale by the LONG edge so portrait and landscape get equal working detail.
_scale = PROC_W / max(im.width, im.height)
work = im.resize((max(1, round(im.width*_scale)), max(1, round(im.height*_scale))), Image.LANCZOS)
a = np.asarray(work).astype(np.float32)

# Optional canvas reshape: extend the frame to a target aspect ratio by adding
# empty space around the photo (never cropping the product). The added margin
# is filled with the synthetic backdrop later, so a portrait shot can be
# presented in a landscape frame.
AR = CFG.get("output_aspect")            # width / height, or null to keep source
if AR:
    ch, cw = a.shape[:2]
    tw, th = cw, ch
    if cw / ch < AR:  tw = int(round(ch * AR))
    else:             th = int(round(cw / AR))
    if (tw, th) != (cw, ch):
        canvas = np.zeros((th, tw, 3), np.float32)
        ox, oy = (tw - cw)//2, int((th - ch) * CFG.get("canvas_v_align", 0.5))
        canvas[oy:oy+ch, ox:ox+cw] = a
        pad_mask = np.zeros((th, tw), bool)
        pad_mask[oy:oy+ch, ox:ox+cw] = True
        a = canvas
    else:
        pad_mask = np.ones((ch, cw), bool)
else:
    pad_mask = np.ones(a.shape[:2], bool)

h, w, _ = a.shape
lum = a.mean(axis=2)

# ---------------------------------------------------------------- flatten backdrop
# Per-column median from bands above/below the product removes the vertical
# specular streak; a per-row pass removes residual top-to-bottom drift.
# Statistics are computed over REAL photo pixels only; padded canvas is masked
# out with NaN so it cannot drag the background model toward black.
ph = np.where(pad_mask, lum, np.nan)
y0, y1 = int(h*0.12), int(h*0.95)
col_bg = np.concatenate([ph[:y0, :], ph[y1:, :]], axis=0)
with np.errstate(all="ignore"):
    col_level = np.nanmedian(col_bg, axis=0)
col_level = np.where(np.isfinite(col_level), col_level, np.nanmedian(col_level))
col_level = ndimage.uniform_filter1d(col_level, odd(w*0.011))
flat = lum - col_level[None, :]

fe = np.where(pad_mask, flat, np.nan)
edge = np.concatenate([fe[:, : int(w*0.06)], fe[:, int(w*0.94):]], axis=1)
with np.errstate(all="ignore"):
    row_level = np.nanmedian(edge, axis=1)
row_level = np.where(np.isfinite(row_level), row_level, 0.0)
flat = flat - ndimage.uniform_filter1d(row_level, odd(h*0.024))[:, None]

flat = np.where(pad_mask, flat, 0.0)      # padding must never look like product
bgpix = np.concatenate([np.where(pad_mask, flat, np.nan)[:y0, :].ravel(),
                        np.where(pad_mask, flat, np.nan)[y1:, :].ravel()])
noise = float(np.nanstd(bgpix))

# ---------------------------------------------------------------- detect product
USE_SEG = CFG.get("use_segmentation", False)
seg_alpha = None
if USE_SEG:
    # A segmentation model answers "which pixels are the product" directly,
    # which threshold masking cannot do reliably when the product's feet are
    # nearly as dark as the backdrop and a specular streak crosses the frame.
    from rembg import remove, new_session
    _sess = new_session(
        CFG.get("segmentation_model", "isnet-general-use"),
        providers=CFG.get("segmentation_providers"),
    )
    cut = remove(Image.fromarray(a.astype(np.uint8)), session=_sess,
                 post_process_mask=True)
    seg_alpha = np.asarray(cut.split()[-1]).astype(np.float32) / 255.0
    subj = seg_alpha > 0.5
    if not subj.any():
        raise SystemExit("Segmentation found no product.")
    lab_s, n_s = ndimage.label(subj)
    subj = lab_s == (np.argmax(ndimage.sum(subj, lab_s, range(1, n_s+1))) + 1)
    subj = ndimage.binary_fill_holes(subj)
    core = subj

# Kernels start relative to the FRAME, then the mask is refined with kernels
# relative to the DETECTED object so small products are not eroded away.
k_frame = odd(w * 0.005)
if not USE_SEG:
    strong = ndimage.binary_opening(flat > CFG["mask_strong_sigma"]*noise, np.ones((k_frame, k_frame)))
    lab, n = ndimage.label(strong)
    if n == 0:
        raise SystemExit("No product detected: the object is not distinguishable from the backdrop.")
    core = lab == (np.argmax(ndimage.sum(strong, lab, range(1, n+1))) + 1)

ys, xs = np.where(core)
obj_w, obj_h = xs.max()-xs.min()+1, ys.max()-ys.min()+1
obj_span = max(obj_w, obj_h)                       # <- drives every later radius

if not USE_SEG:
    # Hysteresis: recover dim parts (feet, soft edges) that touch the core. The
    # weak pass stays INSIDE a dilated core, otherwise a low threshold lets
    # unrelated dark backdrop near the product bleed into the mask.
    weak = ndimage.binary_opening(flat > CFG["mask_weak_sigma"]*noise,
                                  np.ones((odd(obj_span*0.004), odd(obj_span*0.004))))
    reach = odd(obj_span * CFG.get("mask_weak_reach_frac", 0.03))
    weak &= ndimage.binary_dilation(core, np.ones((reach, reach)))
    wl, _ = ndimage.label(weak)
    touch = np.unique(wl[core]); touch = touch[touch > 0]
    subj = np.isin(wl, touch)

    k_obj = odd(obj_span * CFG["mask_close_frac"])
    subj = ndimage.binary_fill_holes(ndimage.binary_closing(subj, np.ones((k_obj, k_obj))))

    # Feet/legs are dim and only partially above threshold, so they arrive as
    # ragged fragments. Closing within a band at the base solidifies them.
    if CFG.get("solidify_base", True):
        ys0, xs0 = np.where(subj)
        body_bot = ys0.max()
        band_top = int(body_bot - (body_bot - ys0.min()) * CFG.get("base_band_frac", 0.22))
        band = np.zeros_like(subj)
        band[band_top:, :] = True
        lower = subj & band
        if lower.any():
            kb = odd(obj_span * CFG.get("base_close_frac", 0.06))
            solid = ndimage.binary_fill_holes(
                ndimage.binary_closing(lower, np.ones((kb, kb))))
            subj = ndimage.binary_fill_holes(subj | (solid & band))

    sl, sn = ndimage.label(subj)
    subj = sl == (np.argmax(ndimage.sum(subj, sl, range(1, sn+1))) + 1)

ys, xs = np.where(subj)
sub_top, sub_bot, sub_l, sub_r = ys.min(), ys.max(), xs.min(), xs.max()
obj_w, obj_h = sub_r-sub_l+1, sub_bot-sub_top+1
obj_span = max(obj_w, obj_h)
frac = obj_span / max(w, h)
print(f"detected product: {obj_w}x{obj_h}px  ({frac*100:.1f}% of frame)  "
      f"bbox x{sub_l}-{sub_r} y{sub_top}-{sub_bot}")
if frac < 0.05:
    print("  WARNING: product is very small in frame; check the result.")

feather = max(1.0, obj_span * CFG["mask_feather_frac"])
if USE_SEG:
    # The model's own soft alpha already describes the edge; just restrict it to
    # the chosen component and give it a light feather for clean compositing.
    alpha = np.where(ndimage.binary_dilation(subj, np.ones((odd(feather*4), odd(feather*4)))),
                     seg_alpha, 0.0)
    alpha = ndimage.gaussian_filter(alpha, feather * 0.6)
    alpha = np.clip((alpha - 0.5) * CFG["mask_edge_contrast"] + 0.5, 0, 1)
else:
    alpha = ndimage.gaussian_filter(subj.astype(np.float32), feather)
    alpha = np.clip((alpha - 0.5) * CFG["mask_edge_contrast"] + 0.5, 0, 1)

# Erode slightly so the dark halo of original backdrop clinging to the product
# edge is not carried onto the new light background.
er = CFG.get("mask_erode_frac", 0.0)
if er > 0:
    k = odd(obj_span * er)
    alpha = np.minimum(alpha, ndimage.grey_erosion(alpha, size=(k, k)))

# Dark-fringe suppression: near the edge, pixels that are nearly as dark as the
# ORIGINAL backdrop are leftover surface/feet-in-shadow, not product. Fading
# them out removes the grey smears that appear once the backdrop turns light.
kill = 0.0 if USE_SEG else CFG.get("dark_fringe_sigma", 0.0)
if kill > 0:
    edge_zone = (alpha > 0.02) & (alpha < 0.995)
    darkness = np.clip(flat / (kill * noise), 0, 1)   # 0 = background-dark
    alpha = np.where(edge_zone, alpha * darkness, alpha)
    alpha = np.clip(alpha, 0, 1)

# contact point = where the object actually meets the surface (robust to shape)
bottom_rows = ys >= sub_bot - max(2, obj_h*0.03)
contact_x = float(xs[bottom_rows].mean())
contact_y = float(sub_bot)

# ---------------------------------------------------------------- backdrop
wall = np.array(CFG["wall_rgb"], np.float32)
table = np.array(CFG["table_rgb"], np.float32)
yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
yn, xn = yy/h, xx/w

# Horizon sits a little below the contact point so the product rests ON the table.
horizon = CFG["horizon_frac"]
if CFG["horizon_follows_product"]:
    horizon = float(np.clip(contact_y/h - CFG["horizon_below_contact"], 0.25, 0.92))
# TWO PHYSICAL PLANES, not a colour gradient. The reference shows a vertical
# wall meeting a horizontal table at a distinct seam (measured at y=0.70, an
# L=66->166 jump), with the table brightening toward the camera and the wall
# darkening downward. A single soft blend reads as "grey soup" and is the
# clearest sign of a composite.
blend = np.clip((yn - horizon) / max(CFG["horizon_softness"], 1e-6) * 0.5 + 0.5, 0, 1)
blend = blend * blend * (3 - 2 * blend)          # smoothstep across the seam

# Wall: falls off toward the seam (light comes from above/behind the camera).
wall_shade = 1.0 - CFG.get("wall_falloff", 0.13) * np.clip(yn / max(horizon, 1e-6), 0, 1)**1.6
wall_px = wall[None, None, :] * wall_shade[..., None]

# Table: recedes away from the camera, so it brightens toward the bottom of the
# frame and darkens as it approaches the seam.
tdepth = np.clip((yn - horizon) / max(1.0 - horizon, 1e-6), 0, 1)
table_shade = (1.0 - CFG.get("table_seam_darken", 0.11)) + CFG.get("table_seam_darken", 0.11) * tdepth**0.75
table_px = table[None, None, :] * table_shade[..., None]

bg = wall_px*(1-blend[...,None]) + table_px*blend[...,None]

# Surface tooth on the TABLE ONLY (the wall is a smooth backdrop). Measured in
# the reference at ~1.3 fine / 2.4 coarse near the seam versus ~0.1 on the
# wall: a real material, not a flat fill.
# NOTE: the tooth is applied AFTER the depth-of-field pass (further below), so
# the defocus cannot erase it. Here we only build the pattern and its profile.
tex_amt = CFG.get("table_texture", 0.0)
if tex_amt > 0:
    trng = np.random.default_rng(11)
    fine = ndimage.gaussian_filter(trng.normal(0, 1, (h, w)), 0.7)
    coarse = ndimage.gaussian_filter(trng.normal(0, 1, (h, w)), 2.6)
    tooth = (fine * 0.55 + coarse * 0.45)
    tooth /= max(tooth.std(), 1e-6)
else:
    tooth = None

# The backdrop must be lit by the SAME key light as the product, otherwise the
# two halves of the image disagree about where the light is.
bl = CFG.get("backdrop_light_strength", 0.0)
if bl > 0:
    ang = np.deg2rad(CFG.get("light_angle_deg", 135.0))
    bg *= (1.0 + bl * np.clip((xn-0.5)*np.cos(ang) - (yn-0.5)*np.sin(ang), -1, 1))[..., None]

r = np.sqrt(((xn-0.5)/0.75)**2 + ((yn-0.45)/0.9)**2)
bg *= (1.0 - CFG["vignette_strength"]*np.clip(r-0.45, 0, None))[..., None]
rng = np.random.default_rng(7)
bg += (ndimage.gaussian_filter(rng.normal(0, 1, (h, w)), 1.1) * CFG["backdrop_grain"])[..., None]

# ---------------------------------------------------------------- contact shadow
# All radii scale with the detected object; anchored at the contact point.
cx = contact_x + CFG["shadow_dx"] * obj_w
cy = contact_y + CFG["shadow_dy"] * obj_h
rx = max(obj_w * CFG["shadow_rx"], 4.0)
ry = max(obj_h * CFG["shadow_ry"], 3.0)
# Ambient occlusion: a tight, dark gradient hugging the product where it meets
# the surface. This contact darkening is what makes an object look SET INTO a
# scene rather than pasted on top of it.
ao_amt = CFG.get("ao_opacity", 0.0)
if ao_amt > 0:
    ao = ndimage.gaussian_filter(subj.astype(np.float32),
                                 max(2.0, obj_span * CFG.get("ao_radius_frac", 0.02)))
    ao = np.clip(ao * CFG.get("ao_gain", 2.4), 0, 1) * (1.0 - alpha)   # outside product only
    ao = ao / max(ao.max(), 1e-6) * ao_amt
else:
    ao = None

# CONTACT SHADOW: a very tight, very dark core exactly where the product touches
# the surface. Measured in the reference at L=64 with pixels reaching 0, against
# a clean table of 189 — this near-black seam is the single strongest cue that
# an object is RESTING on a surface rather than floating above it. The broad
# soft shadow alone averages correctly but never gets dark enough.
contact_amt = CFG.get("contact_opacity", 0.0)
if contact_amt > 0 and subj.any():
    # only the lowest sliver of the silhouette actually touches the surface
    touch_band = np.zeros_like(subj)
    band_px = max(3, int(obj_h * CFG.get("contact_band_frac", 0.06)))
    touch_band[max(0, sub_bot-band_px):sub_bot+1, :] = True
    footprint = (subj & touch_band).astype(np.float32)
    if footprint.any():
        contact = ndimage.gaussian_filter(footprint,
                                          max(1.5, obj_span * CFG.get("contact_radius_frac", 0.012)))
        contact = np.clip(contact * CFG.get("contact_gain", 3.5), 0, 1)
        contact = contact * (1.0 - alpha) * contact_amt
    else:
        contact = None
else:
    contact = None

if CFG["shadow_from_silhouette"]:
    # Squash the product's own silhouette into a ground pool: far more
    # convincing than an ellipse, and automatically the right shape for any
    # product. Scale about the contact point, then blur.
    sq = ndimage.affine_transform(
        subj.astype(np.float32),
        matrix=np.array([[1.0/max(CFG["shadow_squash"], 1e-3), 0.0], [0.0, 1.0]]),
        offset=[contact_y - contact_y/max(CFG["shadow_squash"], 1e-3), 0.0],
        order=1, mode="constant", cval=0.0)
    sh = np.clip(sq, 0, 1)
    sh = ndimage.shift(sh, [CFG["shadow_dy"]*obj_h, CFG["shadow_dx"]*obj_w],
                       order=1, mode="constant", cval=0.0)
else:
    sh = np.exp(-(((xx-cx)/rx)**2 + ((yy-cy)/ry)**2) * 2.2)
sh = ndimage.gaussian_filter(sh, max(2.0, obj_span * CFG["shadow_blur_frac"]))
sh = sh / max(sh.max(), 1e-6) * CFG["shadow_opacity"]
# The cast shadow lies ON the table, so it must not paint across the wall
# behind the seam — a shadow climbing a vertical wall it never touches is a
# giveaway. `blend` is 1 on the table, 0 on the wall.
sh = sh * blend
bg = bg*(1-sh[...,None]) + np.array(CFG["shadow_rgb"], np.float32)[None,None,:]*sh[...,None]
if ao is not None:
    ao = ao * np.clip(blend + CFG.get("ao_on_wall", 0.35), 0, 1)   # mostly on the table
    ao_rgb = np.array(CFG.get("ao_rgb", CFG["shadow_rgb"]), np.float32)
    bg = bg*(1-ao[...,None]) + ao_rgb[None,None,:]*ao[...,None]
if contact is not None:
    c_rgb = np.array(CFG.get("contact_rgb", [26, 24, 21]), np.float32)
    bg = bg*(1-contact[...,None]) + c_rgb[None,None,:]*contact[...,None]

# ---------------------------------------------------------------- grade product
sub = a * np.array(CFG["subject_gain_rgb"], np.float32)[None, None, :]
sub = sub * CFG.get("exposure", 1.0)

# Shadow recovery: the product's own shaded parts (feet, undercuts) were nearly
# black against the dark backdrop and would read as dirty smudges on a light
# background. Lift ONLY the dark end, tapering to zero by mid-tones so the
# glaze and highlights are untouched.
sl_amt = CFG.get("shadow_lift", 0.0)
if sl_amt > 0:
    L = sub.mean(axis=2, keepdims=True)
    knee = CFG.get("shadow_lift_knee", 110.0)
    t = np.clip(1.0 - L/knee, 0, 1) ** CFG.get("shadow_lift_falloff", 1.5)
    sub = sub + sl_amt * t * (knee - L) * CFG.get("shadow_lift_gain", 1.0)

# ---- Directional relight -------------------------------------------------
# The product was photographed under flat frontal light, but the synthetic
# scene has a key light from one side. Without matching the two, the object
# reads as pasted on regardless of how good the mask is. Apply a soft linear
# light ramp across the product plus a rim falloff at its shaded edge.
rl = CFG.get("relight_strength", 0.0)
if rl > 0 and subj.any():
    ang = np.deg2rad(CFG.get("light_angle_deg", 135.0))   # 135 = upper-left
    lx, ly = np.cos(ang), -np.sin(ang)
    # normalised object coordinates (-1..1 across the product's own bbox)
    ox = (xx - (sub_l + sub_r)/2) / max((sub_r - sub_l)/2, 1)
    oy = (yy - (sub_top + sub_bot)/2) / max((sub_bot - sub_top)/2, 1)
    ramp = np.clip(ox*lx + oy*ly, -1, 1)                  # +1 lit, -1 shaded
    gain = 1.0 + rl * ramp
    # extra darkening that hugs the shaded rim, mimicking form shadow
    edge_falloff = CFG.get("relight_edge", 0.0)
    if edge_falloff > 0:
        d = ndimage.distance_transform_edt(subj).astype(np.float32)
        d /= max(d.max(), 1e-6)
        gain -= edge_falloff * np.clip(-ramp, 0, 1) * np.clip(1.0 - d*3.0, 0, 1)
    sub = sub * gain[..., None]

piv = CFG["contrast_pivot"]
sub = (sub - piv) * CFG["contrast"] + piv + CFG["black_lift"]
x01 = np.clip(sub/255.0, 0, 1)
roll = CFG["highlight_rolloff"]
x01 = x01*(1-roll) + (1-(1-x01)**2)*roll
sub = x01 * 255.0
g = sub.mean(axis=2, keepdims=True)
sub = np.clip(g + (sub-g)*CFG["saturation"], 0, 255)

# ---------------------------------------------------------------- depth of field
# A real lens focuses on ONE plane: the product is sharp, and the backdrop
# behind it and the surface in front of it both fall out of focus. Rendering a
# mathematically perfect, uniformly sharp backdrop is one of the strongest
# tells that an image is composited.
dof = CFG.get("dof_strength", 0.0)
if dof > 0:
    # Depth is per-PLANE, not a simple function of height. The wall sits at one
    # far distance (uniformly defocused); the table runs from far at the seam
    # to near at the bottom of the frame, so it comes INTO focus as it
    # approaches the product's plane and softens again in the foreground.
    focus_y = sub_bot / h                      # the product's contact plane
    wall_depth = np.full_like(yn, CFG.get("wall_depth", 1.0))
    table_depth = np.abs(tdepth - np.clip((focus_y - horizon) /
                                          max(1.0 - horizon, 1e-6), 0, 1))
    table_depth = table_depth / max(table_depth.max(), 1e-6)
    depth = wall_depth*(1-blend) + table_depth*blend
    coc = np.clip(depth, 0, 1) ** CFG.get("dof_falloff", 1.3) * dof * obj_span

    # Approximate a variable-radius blur by mixing progressively blurred copies.
    levels = [bg]
    for rad in (obj_span*0.010, obj_span*0.025, obj_span*0.055):
        levels.append(np.stack([ndimage.gaussian_filter(bg[..., c], rad)
                                for c in range(3)], axis=-1))
    radii = np.array([0.0, obj_span*0.010, obj_span*0.025, obj_span*0.055])
    blurred = np.zeros_like(bg)
    wsum = np.zeros((h, w), np.float32)
    for lvl, rad in zip(levels, radii):
        wgt = np.exp(-((coc - rad) / max(obj_span*0.014, 1e-6))**2)
        blurred += lvl * wgt[..., None]
        wsum += wgt
    bg = blurred / np.maximum(wsum, 1e-6)[..., None]

    # Surface tooth goes on AFTER defocus, attenuated by each region's own blur.
    # Applying it before would let the DOF pass erase the very texture that
    # tells the viewer the table is a material and not a painted gradient.
    if tooth is not None:
        sharpness = np.clip(1.0 - coc / max(obj_span*0.030, 1e-6), 0.12, 1.0)
        tex_profile = blend * sharpness
        bg = bg + (tooth * tex_amt * tex_profile)[..., None]

    # The contact seam sits at the focus plane, so it stays sharp. Re-applying
    # it after the DOF pass keeps it crisp instead of being smeared away.
    if contact is not None:
        c_rgb = np.array(CFG.get("contact_rgb", [26, 24, 21]), np.float32)
        bg = bg*(1-contact[...,None]) + c_rgb[None,None,:]*contact[...,None]

# The product itself spans depth: at these apertures its far side is measurably
# softer than its near edge. A uniformly sharp subject on a defocused ground is
# its own kind of tell.
sdof = CFG.get("subject_dof", 0.0)
if sdof > 0 and subj.any():
    near_y = sub_bot                      # nearest part of the product to camera
    far_y  = sub_top
    sd = np.clip((near_y - yy) / max(near_y - far_y, 1), 0, 1) ** 1.5
    soft = np.stack([ndimage.gaussian_filter(sub[..., c], max(1.0, obj_span*sdof))
                     for c in range(3)], axis=-1)
    sub = sub*(1 - sd[..., None]) + soft*sd[..., None]

out = np.clip(bg*(1-alpha[...,None]) + sub*alpha[...,None], 0, 255)
img = Image.fromarray(out.astype(np.uint8))
if CFG["output_width"]:
    _s = CFG["output_width"] / max(img.width, img.height)
    if abs(_s - 1.0) > 1e-3:
        img = img.resize((max(1, round(img.width*_s)), max(1, round(img.height*_s))), Image.LANCZOS)
img.save(DST, quality=95)
print(f"wrote {DST}")
