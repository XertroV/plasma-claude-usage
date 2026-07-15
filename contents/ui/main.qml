import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

PlasmoidItem {
    id: root

    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    // Compact representation only binds to root.* (Plasma instantiates it outside
    // the PlasmoidItem child tree; sibling ids like `controller` are unreliable).
    property string compactName: ""
    property string errorMsg: ""
    property real sessionUsagePercent: 0
    property real weeklyUsagePercent: 0
    property real sessionTimePercent: 0
    property real weeklyTimePercent: 0
    property bool hasSessionWindow: false
    property bool hasWeeklyWindow: false
    property int bankedResets: 0
    property bool isLoading: true
    property int profilesTotal: 0
    property int profilesDone: 0
    property int profilesLoading: 0
    // e.g. "0/1" while fetching, empty once usage is shown
    property string loadingCountText: ""
    property var profileList: []
    property int lastSyncedEpoch: -1
    // Mirrored for fullRepresentation / ExpandedView (sibling ids do not resolve there)
    property int dataEpoch: 0
    property double nowMs: Date.now()
    property string lastGlobalUpdate: ""
    property alias usageController: controller
    property alias i18nObj: i18n

    ProfileController {
        id: controller
        visible: false
        width: 0
        height: 0
        plasmoid: Plasmoid
        i18n: i18n
        Component.onCompleted: {
            bootstrapLegacyProfiles()
            if (profiles.length === 0 && Plasmoid.configuration.discoverOnLoad !== false)
                discoverProfiles()
            root.syncCompactFromController()
        }
        onProfilesChanged: root.syncCompactFromController()
        onDataEpochChanged: root.syncCompactFromController()
        onNowMsChanged: root.syncCompactFromController()
        onDiscoveringChanged: root.syncCompactFromController()
        onLastGlobalUpdateChanged: root.syncCompactFromController()
    }

    // Belt-and-suspenders: poll while anything is still loading so panel never sticks
    Timer {
        id: compactSyncTimer
        interval: 400
        repeat: true
        running: root.isLoading || root.profilesLoading > 0
        onTriggered: root.syncCompactFromController()
    }

    function syncCompactFromController() {
        if (!controller) return
        var list = controller.profiles || []
        // Deep-enough copy for UI: new array + new profile shells so Repeaters update
        var uiList = []
        for (var ci = 0; ci < list.length; ci++) {
            var src = list[ci]
            if (!src) continue
            var row = {}
            for (var ck in src) {
                if (!src.hasOwnProperty(ck)) continue
                if (ck === "windows" && Array.isArray(src[ck])) {
                    var wcopy = []
                    for (var wi = 0; wi < src[ck].length; wi++) {
                        var ww = {}
                        var sw = src[ck][wi]
                        if (sw) {
                            for (var wk in sw) {
                                if (sw.hasOwnProperty(wk)) ww[wk] = sw[wk]
                            }
                        }
                        wcopy.push(ww)
                    }
                    row[ck] = wcopy
                } else {
                    row[ck] = src[ck]
                }
            }
            uiList.push(row)
        }
        profileList = uiList
        dataEpoch = controller.dataEpoch
        nowMs = controller.nowMs
        lastGlobalUpdate = controller.lastGlobalUpdate || ""

        var stats = controller.loadingStats ? controller.loadingStats()
            : { total: list.length, done: 0, loading: 0 }
        profilesTotal = stats.total || 0
        profilesDone = stats.done || 0
        profilesLoading = stats.loading || 0

        var p = null
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].enabled !== false) {
                p = list[i]
                break
            }
        }

        if (!p) {
            compactName = Plasmoid.configuration.displayName
                || defaultProviderLabel()
                || i18n.tr("Loading...")
            errorMsg = ""
            sessionUsagePercent = 0
            weeklyUsagePercent = 0
            sessionTimePercent = 0
            weeklyTimePercent = 0
            hasSessionWindow = false
            hasWeeklyWindow = false
            bankedResets = 0
            isLoading = !!controller.discovering || profilesTotal === 0
            loadingCountText = controller.discovering
                ? (profilesTotal > 0 ? (profilesDone + "/" + profilesTotal) : "…")
                : (profilesTotal > 0 ? (profilesDone + "/" + profilesTotal) : "")
            return
        }

        compactName = p.displayName || p.id || defaultProviderLabel()
        errorMsg = p.error || ""
        bankedResets = p.bankedResets || 0

        var primaries = []
        var wins = p.windows || []
        for (var j = 0; j < wins.length; j++) {
            var w = wins[j]
            // Accept primary windows; also any visible window if role missing
            if (!w) continue
            var isPrimary = (w.role === "primary" || w.role === "" || w.role === undefined)
            var isVisible = (w.visible !== false)
            if (isVisible && isPrimary)
                primaries.push(w)
        }
        // Fallback: if nothing marked primary, use first two visible windows
        if (primaries.length === 0) {
            for (var k = 0; k < wins.length; k++) {
                if (wins[k] && wins[k].visible !== false)
                    primaries.push(wins[k])
            }
        }

        if (primaries.length >= 2) {
            hasSessionWindow = true
            hasWeeklyWindow = true
            sessionUsagePercent = Number(primaries[0].usagePercent) || 0
            sessionTimePercent = Number(primaries[0].timePercent) || 0
            weeklyUsagePercent = Number(primaries[1].usagePercent) || 0
            weeklyTimePercent = Number(primaries[1].timePercent) || 0
        } else if (primaries.length === 1) {
            hasSessionWindow = true
            hasWeeklyWindow = false
            sessionUsagePercent = Number(primaries[0].usagePercent) || 0
            sessionTimePercent = Number(primaries[0].timePercent) || 0
            weeklyUsagePercent = 0
            weeklyTimePercent = 0
        } else {
            hasSessionWindow = false
            hasWeeklyWindow = false
            sessionUsagePercent = 0
            weeklyUsagePercent = 0
            sessionTimePercent = 0
            weeklyTimePercent = 0
        }

        var stillLoading = !!controller.discovering
            || profilesLoading > 0
            || (profilesTotal > 0 && profilesDone < profilesTotal)
            || (!!p.loading)
            || (errorMsg === "" && !hasSessionWindow && !hasWeeklyWindow && !p.lastFetchMs)

        isLoading = stillLoading
        if (stillLoading || (profilesTotal > 1 && profilesDone < profilesTotal))
            loadingCountText = profilesDone + "/" + Math.max(profilesTotal, 1)
        else
            loadingCountText = ""

        if (controller.dataEpoch !== lastSyncedEpoch) {
            lastSyncedEpoch = controller.dataEpoch
            console.log("Claude Usage: sync compact name=", compactName,
                        "loading=", isLoading, "count=", loadingCountText,
                        "wins=", wins.length, "primary=", primaries.length,
                        "sess=", sessionUsagePercent, "week=", weeklyUsagePercent,
                        "err=", errorMsg)
        }
    }

    function defaultProviderLabel() {
        var provider = Plasmoid.configuration.provider || "claude"
        if (provider === "codex") return "Codex"
        if (provider === "zai") return "Z.ai"
        if (provider === "grok") return "Grok"
        if (provider === "opencode") {
            var sub = Plasmoid.configuration.opencodeSubProvider || "anthropic"
            var names = { "anthropic": "Claude", "openai": "Codex", "zai": "Z.ai", "kimi": "Kimi", "gemini": "Gemini" }
            return names[sub] || sub
        }
        return Plasmoid.configuration.displayName || "Claude"
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function capacityPaceColor(pace) {
        if (pace <= 1.0) return Kirigami.Theme.positiveTextColor
        if (pace < 2.0) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function efficiencyPaceColor(pace, timePercent) {
        var remaining = 1.0 - Math.min(timePercent, 100) / 100
        var upperGreen = 1.0 + remaining * 1.0
        var upperOrange = 1.0 + remaining * 3.0
        var lowerBlue = 0.25 * remaining
        if (pace < lowerBlue) return Kirigami.Theme.activeTextColor
        if (pace <= upperGreen) return Kirigami.Theme.positiveTextColor
        if (pace < upperOrange) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function getSessionColor() {
        if (root.sessionTimePercent > 0) {
            var timeP = Math.max(1, root.sessionTimePercent)
            var pace = root.sessionUsagePercent / timeP
            var mode = Plasmoid.configuration.sessionColorMode || "capacity"
            return mode === "efficiency" ? efficiencyPaceColor(pace, timeP) : capacityPaceColor(pace)
        }
        return getUsageColor(root.sessionUsagePercent)
    }

    function getWeeklyColor() {
        if (root.weeklyTimePercent > 0) {
            var timeP = Math.max(1, root.weeklyTimePercent)
            var pace = root.weeklyUsagePercent / timeP
            var mode = Plasmoid.configuration.weeklyColorMode || "efficiency"
            return mode === "efficiency" ? efficiencyPaceColor(pace, timeP) : capacityPaceColor(pace)
        }
        return getUsageColor(root.weeklyUsagePercent)
    }

    function primaryWindowsFor(profile) {
        var out = []
        if (!profile || !profile.windows) return out
        for (var i = 0; i < profile.windows.length; i++) {
            var w = profile.windows[i]
            if (!w || w.visible === false) continue
            if (w.role === "primary" || !w.role)
                out.push(w)
        }
        if (out.length === 0) {
            for (var j = 0; j < profile.windows.length; j++) {
                if (profile.windows[j] && profile.windows[j].visible !== false)
                    out.push(profile.windows[j])
            }
        }
        return out
    }

    function windowDotColor(win, index) {
        if (!win) return Kirigami.Theme.textColor
        var mode = index === 0
            ? (Plasmoid.configuration.sessionColorMode || "capacity")
            : (Plasmoid.configuration.weeklyColorMode || "efficiency")
        return QC.windowPaceColor(win, mode, Kirigami.Theme)
    }

    // Prefer compact in the panel (same pattern as pre-refactor + other Plasma applets)
    preferredRepresentation: compactRepresentation
    switchWidth: Kirigami.Units.gridUnit * 16
    switchHeight: Kirigami.Units.gridUnit * 12

    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Math.max(Kirigami.Units.iconSizes.medium, usageRow.implicitHeight)
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: Math.max(Kirigami.Units.iconSizes.medium, usageRow.implicitHeight)

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignVCenter
                source: Qt.resolvedUrl("../icons/claude.svg")
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Multi-profile: stacked lines (capped so compact never overflows the panel)
            ColumnLayout {
                id: multiColumn
                spacing: 1
                visible: root.profileList.length > 1
                // Hard cap visual height in compact representation
                readonly property int maxRows: 6

                Repeater {
                    model: root.profileList

                    RowLayout {
                        required property var modelData
                        required property int index
                        spacing: 4
                        visible: modelData && modelData.enabled !== false
                                 && index < multiColumn.maxRows

                        PlasmaComponents.Label {
                            text: modelData.error ? "⚠" : (modelData.displayName || modelData.id || "?")
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            color: modelData.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                            elide: Text.ElideRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            Layout.maximumWidth: Kirigami.Units.gridUnit * 5
                        }

                        Repeater {
                            model: root.primaryWindowsFor(modelData)

                            RowLayout {
                                required property var modelData
                                required property int index
                                spacing: 3

                                PlasmaComponents.Label {
                                    visible: index > 0
                                    text: "|"
                                    opacity: 0.4
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                }
                                PaceBar {
                                    Layout.preferredWidth: 22
                                    Layout.preferredHeight: 6
                                    usagePercent: modelData.usagePercent || 0
                                    timePercent: modelData.timePercent || 0
                                    colorMode: index === 0
                                        ? (Plasmoid.configuration.sessionColorMode || "capacity")
                                        : (Plasmoid.configuration.weeklyColorMode || "efficiency")
                                    compact: true
                                    windowData: modelData
                                }
                                PlasmaComponents.Label {
                                    text: Math.round(modelData.usagePercent || 0) + "%"
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    font.bold: true
                                    color: root.windowDotColor(modelData, index)
                                }
                            }
                        }

                        PlasmaComponents.Label {
                            visible: !!modelData.loading && !(modelData.windows && modelData.windows.length)
                            text: "…"
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        }

                        PlasmaComponents.Label {
                            visible: !!modelData.error
                            text: modelData.error
                            color: Kirigami.Theme.negativeTextColor
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            elide: Text.ElideRight
                            Layout.maximumWidth: Kirigami.Units.gridUnit * 5
                        }
                    }
                }

                PlasmaComponents.Label {
                    visible: root.profileList.length > multiColumn.maxRows
                    text: "+" + (root.profileList.length - multiColumn.maxRows) + " more"
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }

                PlasmaComponents.Label {
                    visible: root.isLoading
                    text: root.profilesDone + "/" + Math.max(root.profilesTotal, 1)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    font.bold: true
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Single-profile (legacy panel instances): classic strip
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                visible: root.profileList.length <= 1

                PlasmaComponents.Label {
                    text: root.compactName
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.textColor
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 6
                }

                PlasmaComponents.Label {
                    visible: root.errorMsg !== ""
                    text: "⚠"
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                    color: Kirigami.Theme.negativeTextColor
                }

                PaceBar {
                    visible: root.errorMsg === "" && root.hasSessionWindow
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 8
                    usagePercent: root.sessionUsagePercent
                    timePercent: root.sessionTimePercent
                    colorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                    compact: true
                }

                PlasmaComponents.Label {
                    visible: root.errorMsg === "" && root.hasSessionWindow
                    text: Math.round(root.sessionUsagePercent) + "%"
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                    font.bold: true
                    color: root.getSessionColor()
                }

                PlasmaComponents.Label {
                    visible: root.errorMsg === "" && root.hasSessionWindow && root.hasWeeklyWindow
                    text: "|"
                    opacity: 0.5
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                }

                PaceBar {
                    visible: root.errorMsg === "" && root.hasWeeklyWindow
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 8
                    usagePercent: root.weeklyUsagePercent
                    timePercent: root.weeklyTimePercent
                    colorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                    compact: true
                }

                PlasmaComponents.Label {
                    visible: root.errorMsg === "" && root.hasWeeklyWindow
                    text: Math.round(root.weeklyUsagePercent) + "%"
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                    font.bold: true
                    color: root.getWeeklyColor()
                }

                PlasmaComponents.Label {
                    visible: root.bankedResets > 0 && Plasmoid.configuration.showBankedBadge !== false
                    text: "↻" + root.bankedResets
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.highlightColor
                }

                PlasmaComponents.Label {
                    visible: root.errorMsg !== ""
                    text: root.errorMsg
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                }

                PlasmaComponents.Label {
                    visible: root.isLoading && root.errorMsg === ""
                             && !root.hasSessionWindow && !root.hasWeeklyWindow
                    text: root.loadingCountText !== ""
                          ? root.loadingCountText
                          : (root.profilesTotal > 0
                             ? (root.profilesDone + "/" + root.profilesTotal)
                             : "…")
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                    font.bold: true
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }
    }

    fullRepresentation: Item {
        // Bounded size: do NOT grow preferredHeight with content (that overflows
        // plasmoidviewer when many profiles load). Content scrolls inside ExpandedView.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 24
        Layout.maximumWidth: Kirigami.Units.gridUnit * 40
        clip: true

        ColumnLayout {
            id: expandedColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: root.i18nObj ? root.i18nObj.tr("Usage quotas") : "Usage quotas"
                font.bold: true
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
                elide: Text.ElideRight
            }

            ExpandedView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Only root.* — bare `controller` / `i18n` are null in this representation
                profiles: root.profileList
                dataEpoch: root.dataEpoch
                nowMs: root.nowMs
                lastGlobalUpdate: root.lastGlobalUpdate
                profilesDone: root.profilesDone
                profilesTotal: root.profilesTotal
                isLoading: root.isLoading
                i18n: root.i18nObj
                sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
                onRefreshRequested: {
                    if (root.usageController) root.usageController.refreshAll()
                }
                onRediscoverRequested: {
                    if (root.usageController) root.usageController.discoverProfiles()
                }
            }
        }
    }

    function tooltipText() {
        var list = root.profileList || []
        if (!list.length)
            return root.isLoading
                ? ((root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1)))
                   + " — " + (root.i18nObj ? root.i18nObj.tr("Loading...") : "Loading..."))
                : (root.compactName || "—")
        var lines = []
        for (var i = 0; i < list.length; i++) {
            var p = list[i]
            if (!p || p.enabled === false) continue
            var parts = []
            var wins = p.windows || []
            for (var j = 0; j < wins.length; j++) {
                if (wins[j].visible === false) continue
                var cd = QC.formatCountdown(wins[j].resetAtMs, root.nowMs)
                parts.push(wins[j].label + " " + Math.round(wins[j].usagePercent) + "%"
                    + (cd ? " (" + cd + ")" : ""))
            }
            if (p.bankedResets > 0) parts.push("↻" + p.bankedResets)
            if (parts.length) lines.push((p.displayName || p.id) + ": " + parts.join(" | "))
            else if (p.error) lines.push((p.displayName || p.id) + ": " + p.error)
            else if (p.loading) lines.push((p.displayName || p.id) + ": "
                + (root.profilesDone + "/" + Math.max(root.profilesTotal, 1)))
            else lines.push((p.displayName || p.id) + ": —")
        }
        if (lines.length) return lines.join("\n")
        return root.compactName || (root.i18nObj ? root.i18nObj.tr("Loading...") : "Loading...")
    }

    Plasmoid.icon: "claude-usage"
    toolTipMainText: i18n.tr("AI Usage")
    toolTipSubText: tooltipText()

    Component.onCompleted: {
        console.log("Claude Usage: multi-profile widget loaded")
        syncCompactFromController()
    }
}
