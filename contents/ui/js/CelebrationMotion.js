.pragma library

function clamp01(value) {
    var number = Number(value)
    if (!isFinite(number)) return 0
    return Math.max(0, Math.min(1, number))
}

function smooth(value) {
    var t = clamp01(value)
    return t * t * (3 - 2 * t)
}

function mix(from, to, amount) {
    return from + (to - from) * amount
}

function state(scale, translateX, washOpacity, glyphOpacity,
               glyphScale, glyphY, borderMix, borderWidth, reducedMotion) {
    return {
        scale: reducedMotion ? 1 : scale,
        translateX: reducedMotion ? 0 : translateX,
        washOpacity: washOpacity,
        glyphOpacity: glyphOpacity,
        glyphScale: glyphScale,
        glyphY: glyphY,
        borderMix: borderMix,
        borderWidth: borderWidth
    }
}

/**
 * Deterministic quota-reset celebration choreography.
 * Segments: anticipation (0-.12), focal peak (.12-.38), damped accent
 * (.38-.62), and a quiet resolve (.62-1).
 */
function at(progress, reducedMotion) {
    var p = clamp01(progress)
    var reduced = reducedMotion === true

    if (p <= 0 || p >= 1)
        return state(1, 0, 0, 0, 0.78, 0, 0, 1, reduced)

    if (p < 0.12) {
        var anticipation = smooth(p / 0.12)
        return state(
            mix(1, 0.992, anticipation),
            mix(0, -1.4, anticipation),
            mix(0, 0.14, anticipation),
            mix(0, 0.24, anticipation),
            mix(0.78, 0.86, anticipation),
            mix(0, 2, anticipation),
            mix(0, 0.28, anticipation),
            mix(1, 1.35, anticipation),
            reduced)
    }

    if (p < 0.38) {
        var peak = smooth((p - 0.12) / 0.26)
        return state(
            mix(0.992, 1.042, peak),
            mix(-1.4, 3.5, peak),
            mix(0.14, 0.68, peak),
            mix(0.24, 1, peak),
            mix(0.86, 1.08, peak),
            mix(2, -2, peak),
            mix(0.28, 1, peak),
            mix(1.35, 2, peak),
            reduced)
    }

    if (p < 0.62) {
        var accent = smooth((p - 0.38) / 0.24)
        var damping = 1 - accent
        return state(
            mix(1.042, 1.008, accent),
            3.5 * damping * Math.cos(accent * Math.PI * 2),
            mix(0.68, 0.42, accent),
            mix(1, 0.72, accent),
            mix(1.08, 0.96, accent),
            mix(-2, -4, accent),
            mix(1, 0.65, accent),
            mix(2, 1.7, accent),
            reduced)
    }

    var resolve = smooth((p - 0.62) / 0.38)
    return state(
        mix(1.008, 1, resolve),
        0,
        mix(0.42, 0, resolve),
        mix(0.72, 0, resolve),
        mix(0.96, 0.82, resolve),
        mix(-4, -8, resolve),
        mix(0.65, 0, resolve),
        mix(1.7, 1, resolve),
        reduced)
}
