.pragma library
.import "QuotaCommon.js" as QC

function presentProfile(profile, options) {
    var rows = []
    if (!profile || !Array.isArray(profile.windows))
        return { rows: rows }

    var modes = options || {}
    for (var i = 0; i < profile.windows.length; i++) {
        var windowData = profile.windows[i]
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
