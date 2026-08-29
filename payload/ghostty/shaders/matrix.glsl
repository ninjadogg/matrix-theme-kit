// Matrix digital rain, composited BEHIND the terminal text.
//
// iChannel0 holds Ghostty's rendered screen. Terminal background is black, so
// pixel luminance separates glyphs from empty cells.
//
// Two things worth knowing if you tweak this:
//
// 1. Ghostty's fragCoord origin is TOP-LEFT, not bottom-left like Shadertoy.
//    So cell.y already counts downward and needs no flip -- flipping it makes
//    the rain fall upward.
//
// 2. Dimming the rain alone does not make text readable; faint glyphs directly
//    behind a character still break its shape. What works is a halo: sample the
//    neighbourhood of each pixel and suppress rain near anything the terminal
//    drew, so every glyph keeps a dark gutter around it.

const float CELL_W = 11.0;    // column width in px
const float CELL_H = 17.0;    // glyph cell height in px
const float SPEED_MIN = 4.0;  // cells/sec for the slowest column
const float SPEED_MAX = 14.0;
const float TAIL_MIN = 10.0;  // trail length in cells
const float TAIL_MAX = 26.0;
const float MUTATE_HZ = 7.0;  // how often a visible glyph reshuffles
const float DENSITY = 0.55;   // fraction of columns that ever rain
const float RAIN_GAIN = 0.30; // overall rain brightness vs. your text
const float HALO_PX = 2.5;    // radius of the clear gutter around glyphs

// Palette lifted from the Claude Code Matrix theme so the rain and the UI
// share one phosphor ramp.
const vec3 HEAD = vec3(0.84, 1.00, 0.84);
const vec3 BRIGHT = vec3(0.00, 1.00, 0.25);
const vec3 BODY = vec3(0.00, 0.67, 0.20);
const vec3 FADE = vec3(0.00, 0.30, 0.11);

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    return fract(p * (p + p));
}

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// A blocky 5x5 pseudo-glyph. Real katakana would need a font atlas; at this
// cell size the eye reads structured on/off noise as code just as well.
float glyphMask(vec2 cellUV, float seed) {
    vec2 g = floor(cellUV * 5.0);
    // keep a gutter so adjacent cells don't fuse into a solid block
    if (g.x < 0.5 || g.x > 3.5) return 0.0;
    return step(0.45, hash21(g + seed * 17.0));
}

// Brightest terminal pixel within HALO_PX -- an 8-tap ring plus centre.
float neighbourhoodLum(vec2 uv) {
    vec2 r = vec2(HALO_PX) / iResolution.xy;
    float m = lum(texture(iChannel0, uv).rgb);
    m = max(m, lum(texture(iChannel0, uv + vec2( r.x, 0.0)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2(-r.x, 0.0)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2(0.0,  r.y)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2(0.0, -r.y)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2( r.x,  r.y)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2( r.x, -r.y)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2(-r.x,  r.y)).rgb));
    m = max(m, lum(texture(iChannel0, uv + vec2(-r.x, -r.y)).rgb));
    return m;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    float rows = iResolution.y / CELL_H;
    vec2 cell = floor(fragCoord / vec2(CELL_W, CELL_H));
    vec2 cellUV = fract(fragCoord / vec2(CELL_W, CELL_H));

    float colSeed = hash11(cell.x);
    vec3 rain = vec3(0.0);

    // Only some columns rain, so the field has gaps instead of reading as a
    // uniform curtain.
    if (colSeed < DENSITY) {
        float speed = mix(SPEED_MIN, SPEED_MAX, hash11(cell.x + 11.7));
        float tail = mix(TAIL_MIN, TAIL_MAX, hash11(cell.x + 3.1));
        float phase = colSeed * 137.0;

        // Top-left origin: cell.y already increases downward.
        float head = mod(iTime * speed + phase, rows + tail);
        float dist = head - cell.y;

        if (dist >= 0.0 && dist < tail) {
            float t = dist / tail;
            float bright = 1.0 - t;
            bright *= bright; // bias brightness toward the head

            vec3 col;
            if (dist < 1.0) col = HEAD;
            else if (t < 0.18) col = BRIGHT;
            else if (t < 0.55) col = mix(BRIGHT, BODY, (t - 0.18) / 0.37);
            else col = mix(BODY, FADE, (t - 0.55) / 0.45);

            float seed = floor(hash21(cell) * 97.0)
                       + floor(iTime * MUTATE_HZ) * step(0.5, hash21(cell + 5.0));
            rain = col * glyphMask(cellUV, seed) * bright * RAIN_GAIN;
        }
    }

    // Text wins where the terminal drew, and rain backs off around it.
    float own = lum(term.rgb);
    float textMask = smoothstep(0.015, 0.10, own);
    float clear = 1.0 - smoothstep(0.010, 0.075, neighbourhoodLum(uv));

    vec3 outCol = mix(rain * clear, term.rgb, textMask);
    fragColor = vec4(outCol, 1.0);
}
