.pragma library
.import "QuotaCommon.js" as QC

/**
 * QML `var` properties sometimes reify JS arrays as array-like objects where
 * Array.isArray() is false. Accept any length-bearing sequence so presentation
 * still works after objects cross QML property bindings.
 */
function windowsList(profile) {
    if (!profile)
        return null
    var windows = profile.windows
    if (windows === undefined || windows === null)
        return null
    if (Array.isArray(windows))
        return windows
    // Reject strings/functions (they have .length but are not window lists)
    if (typeof windows === "string" || typeof windows === "function")
        return null
    // Array-like (QVariantList / QJSValue list): numeric length, index access
    if (typeof windows === "object" && typeof windows.length === "number"
            && windows.length >= 0)
        return windows
    return null
}

function presentProfile(profile, options) {
    var rows = []
    var windows = windowsList(profile)
    if (!windows)
        return { rows: rows }

    var modes = options || {}
    var n = windows.length
    for (var i = 0; i < n; i++) {
        var windowData = windows[i]
        if (!windowData || windowData.visible === false)
            continue
        rows.push({
            windowData: windowData,
            label: QC.displayWindowLabel(windowData),
            colorMode: QC.colorModeForWindow(
                windowData,
                modes.sessionColorMode,
                modes.weeklyColorMode
            )
        })
    }
    return { rows: rows }
}
