unit RiderClothShader;

{$mode objfpc}{$H+}

interface

{ Shared by the runtime and Avatar Editor. Keep fabric masks and tone
  preservation identical in all previews. }
const
  RIDER_CLOTH_DYE_GLSL =
    'uniform vec3 uDye;' + LineEnding +
    'uniform vec3 uDyeKey;' + LineEnding +
    'uniform float uDyeAmt;' + LineEnding +
    'uniform float uDyeKind;' + LineEnding +
    'float cloth_hue(vec3 c)' + LineEnding +
    '{' + LineEnding +
    '  float mx = max(c.r, max(c.g, c.b));' + LineEnding +
    '  float mn = min(c.r, min(c.g, c.b));' + LineEnding +
    '  float d = mx - mn;' + LineEnding +
    '  if (d < 1e-5) return 0.0;' + LineEnding +
    '  float h;' + LineEnding +
    '  if ((mx - c.r) <= (mx - c.g) && (mx - c.r) <= (mx - c.b))' + LineEnding +
    '    h = 60.0 * ((c.g - c.b) / d);' + LineEnding +
    '  else if ((mx - c.g) <= (mx - c.b))' + LineEnding +
    '    h = 60.0 * ((c.b - c.r) / d + 2.0);' + LineEnding +
    '  else' + LineEnding +
    '    h = 60.0 * ((c.r - c.g) / d + 4.0);' + LineEnding +
    '  if (h < 0.0) h += 360.0;' + LineEnding +
    '  return h;' + LineEnding +
    '}' + LineEnding +
    'bool cloth_is_key(vec3 src, vec3 key)' + LineEnding +
    '{' + LineEnding +
    '  float mx = max(src.r, max(src.g, src.b));' + LineEnding +
    '  float mn = min(src.r, min(src.g, src.b));' + LineEnding +
    '  float sat = (mx < 1e-5) ? 0.0 : (mx - mn) / mx;' + LineEnding +
    '  float h = cloth_hue(src);' + LineEnding +
    '  int k = int(uDyeKind + 0.5);' + LineEnding +
    '  if (k == 6) {' + LineEnding +
    '    if (src.b < src.r * 0.70 || mx < 0.05) return false;' + LineEnding +
    '    if (src.b <= src.g + 0.04) return false;' + LineEnding +
    '    return (src.b - min(src.r, src.g)) >= 0.003;' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 5) {' + LineEnding +
    '    if (mx < 0.10 || sat < 0.18) return false;' + LineEnding +
    '    if (src.r <= src.g + 0.025) return false;' + LineEnding +
    '    if (src.g < src.b * 0.88) return false;' + LineEnding +
    '    float dhs = abs(h - cloth_hue(key));' + LineEnding +
    '    dhs = min(dhs, 360.0 - dhs);' + LineEnding +
    '    return dhs < 28.0;' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 1) {' + LineEnding +
    '    if (mx < 0.04) return false;' + LineEnding +
    '    if (src.r > src.g + 0.02 && src.g >= src.b * 0.90 && src.r > src.b' + LineEnding +
    '        && (h < 50.0 || h > 320.0)) return false;' + LineEnding +
    '    if ((h >= 300.0 || h <= 22.0) && src.r > src.g + 0.04 && sat > 0.10)' + LineEnding +
    '      return false;' + LineEnding +
    '    return true;' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 0) {' + LineEnding +
    '    if (mx < 0.20) return false;' + LineEnding +
    '    return (sat >= 0.10 && src.r > src.g + 0.04 && (h >= 300.0 || h <= 22.0))' + LineEnding +
    '      || (src.r > src.g + 0.003 && src.b > src.g + 0.002 && src.r >= src.b * 0.85);' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 2) {' + LineEnding +
    '    if (mx < 0.12 || sat < 0.08) return false;' + LineEnding +
    '    if (src.r <= src.b + 0.03 || src.g <= src.b + 0.02) return false;' + LineEnding +
    '    return h >= 28.0 && h <= 105.0;' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 3) {' + LineEnding +
    '    if (mx < 0.14 || sat < 0.04) return false;' + LineEnding +
    '    if (src.b < src.g || src.r < src.g) return false;' + LineEnding +
    '    return (h >= 250.0) || (h <= 30.0);' + LineEnding +
    '  }' + LineEnding +
    '  if (k == 4) {' + LineEnding +
    '    if (mx < 0.08 || sat < 0.015) return false;' + LineEnding +
    '    if (src.r > src.g + 0.035 && src.g >= src.b * 0.90) return false;' + LineEnding +
    '    if (src.b > src.g + 0.025 && src.b > src.r + 0.02) return false;' + LineEnding +
    '    if (sat <= 0.16 && mx <= 0.48) return true;' + LineEnding +
    '    return (src.b <= src.g && src.r <= src.g + 0.02)' + LineEnding +
    '      && (h >= 45.0 && h <= 165.0);' + LineEnding +
    '  }' + LineEnding +
    '  if (mx < 0.22 || sat < 0.10) return false;' + LineEnding +
    '  float dh = abs(h - cloth_hue(key));' + LineEnding +
    '  dh = min(dh, 360.0 - dh);' + LineEnding +
    '  return dh < 28.0;' + LineEnding +
    '}' + LineEnding +
    'vec3 cloth_dye(vec3 src, vec3 dye, vec3 key, float amt)' + LineEnding +
    '{' + LineEnding +
    '  float lum = dot(src, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
    '  float nat = max(dot(key, vec3(0.2126, 0.7152, 0.0722)), 0.05);' + LineEnding +
    '  float dl = dot(dye, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
    '  float ratio = lum / nat;' + LineEnding +
    '  float w = clamp(dl / 0.18, 0.0, 1.0);' + LineEnding +
    '  float ld = w * (dl * ratio) + (1.0 - w) * (dl + 0.5 * (lum - nat));' + LineEnding +
    '  ld = clamp(ld, 0.0, 1.0);' + LineEnding +
    '  vec3 dyed;' + LineEnding +
    '  if (dl < 1e-4)' + LineEnding +
    '    dyed = vec3(ld);' + LineEnding +
    '  else {' + LineEnding +
    '    dyed = dye * (ld / dl);' + LineEnding +
    '    float m = max(dyed.r, max(dyed.g, dyed.b));' + LineEnding +
    '    if (m > 1.0) dyed /= m;' + LineEnding +
    '  }' + LineEnding +
    '  if (int(uDyeKind + 0.5) == 0) {' + LineEnding +
    '    float cov = clamp((src.r - src.g) / max(src.r * 0.28, 0.0001), 0.0, 1.0);' + LineEnding +
    '    dyed = mix(vec3(src.g), dyed, cov);' + LineEnding +
    '  }' + LineEnding +
    '  return mix(src, dyed, clamp(amt, 0.0, 1.0));' + LineEnding +
    '}' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  if (uDyeAmt > 1e-4 && cloth_is_key(fragment_color.rgb, uDyeKey))' + LineEnding +
    '    fragment_color.rgb = cloth_dye(fragment_color.rgb, uDye, uDyeKey, uDyeAmt);' + LineEnding +
    '}';

implementation
end.
