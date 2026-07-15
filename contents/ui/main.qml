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
        return QC.primaryWindows(profile)
    }

    function openDetailFor(profile) {
        if (!profile) {
            var list = root.profileList || []
            for (var i = 0; i < list.length; i++) {
                if (list[i] && list[i].enabled !== false) {
                    profile = list[i]
                    break
                }
            }
        }
        if (!profile) return
        detailWindow.profiles = root.profileList
        detailWindow.nowMs = root.nowMs
        detailWindow.sessionColorMode = Plasmoid.configuration.sessionColorMode || "capacity"
        detailWindow.weeklyColorMode = Plasmoid.configuration.weeklyColorMode || "efficiency"
        detailWindow.i18n = root.i18nObj
        detailWindow.showFor(profile)
    }

    function enabledProfiles() {
        var out = []
        var list = root.profileList || []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].enabled !== false)
                out.push(list[i])
        }
        return out
    }

    DetailWindow {
        id: detailWindow
        profiles: root.profileList
        nowMs: root.nowMs
        sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
        weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
        i18n: root.i18nObj
        onRefreshRequested: {
            if (root.usageController) root.usageController.refreshAll()
        }
        onConfigureRequested: {
            try {
                Plasmoid.internalAction("configure").trigger()
            } catch (e) {
                console.log("Claude Usage: configure action failed", e)
            }
        }
    }

    // Panel is the product — cards with primary quotas (no day-to-day popup)
    preferredRepresentation: compactRepresentation
    switchWidth: Kirigami.Units.gridUnit * 20
    switchHeight: Kirigami.Units.gridUnit * 8

    compactRepresentation: Item {
        id: compactRoot

        readonly property int cardMinW: Kirigami.Units.gridUnit * 11
        readonly property int hPad: Kirigami.Units.smallSpacing
        readonly property int vPad: Kirigami.Units.smallSpacing
        readonly property var cards: root.enabledProfiles()
        readonly property int maxCards: 8

        // Implicit size drives Plasma panel allocation
        implicitWidth: Math.max(Kirigami.Units.gridUnit * 12,
                                cardFlow.implicitWidth + hPad * 2 + iconCol.implicitWidth + Kirigami.Units.smallSpacing)
        implicitHeight: Math.max(Kirigami.Units.iconSizes.medium,
                                 cardFlow.implicitHeight + vPad * 2)

        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight

        RowLayout {
            id: usageRow
            anchors.fill: parent
            anchors.margins: 0
            spacing: Kirigami.Units.smallSpacing

            ColumnLayout {
                id: iconCol
                Layout.alignment: Qt.AlignTop
                spacing: Kirigami.Units.smallSpacing / 2
                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    source: Qt.resolvedUrl("../icons/claude.svg")
                }
                PlasmaComponents.Label {
                    visible: root.isLoading
                    text: root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1))
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Auto-flow account cards
            Flow {
                id: cardFlow
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignTop | Qt.AlignLeft
                spacing: Kirigami.Units.smallSpacing
                flow: Flow.LeftToRight

                Repeater {
                    model: {
                        var _ = root.dataEpoch
                        return compactRoot.cards
                    }
                    AccountCard {
                        required property var modelData
                        required property int index
                        visible: index < compactRoot.maxCards
                        profile: modelData
                        nowMs: root.nowMs
                        sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                        weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                        showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
                        minWidth: compactRoot.cardMinW
                        // Fill width efficiently when only one card, or when row has room
                        width: {
                            var avail = cardFlow.width
                            if (avail <= 0) return minWidth
                            var cols = Math.max(1, Math.floor((avail + cardFlow.spacing) / (minWidth + cardFlow.spacing)))
                            var n = Math.min(compactRoot.cards.length, compactRoot.maxCards)
                            if (n <= 1) return Math.max(minWidth, avail)
                            var w = Math.floor((avail - cardFlow.spacing * (cols - 1)) / cols)
                            return Math.max(minWidth, w)
                        }
                        onDetailRequested: function(p) { root.openDetailFor(p) }
                    }
                }

                // Ghost cards while discovering with no profiles yet
                Repeater {
                    model: (compactRoot.cards.length === 0 && root.isLoading) ? 2 : 0
                    AccountCard {
                        profile: ({ displayName: "…", loading: true, windows: [], error: "" })
                        nowMs: root.nowMs
                        minWidth: compactRoot.cardMinW
                        width: Math.max(minWidth, Math.floor((cardFlow.width - cardFlow.spacing) / 2) || minWidth)
                    }
                }

                PlasmaComponents.Label {
                    visible: compactRoot.cards.length > compactRoot.maxCards
                    text: "+" + (compactRoot.cards.length - compactRoot.maxCards) + " more"
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }

                PlasmaComponents.Label {
                    visible: compactRoot.cards.length === 0 && !root.isLoading
                    text: root.i18nObj ? root.i18nObj.tr("No profiles") : "No profiles"
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }
    }

    // Popup deprioritized: short help + open detail / configure
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 10

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: root.i18nObj ? root.i18nObj.tr("AI Usage") : "AI Usage"
                font.bold: true
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: root.i18nObj
                      ? root.i18nObj.tr("Quotas are shown on the panel. Open details for paths and extra limits.")
                      : "Quotas are shown on the panel. Open details for paths and extra limits."
                color: Kirigami.Theme.disabledTextColor
            }
            RowLayout {
                PlasmaComponents.Button {
                    text: root.i18nObj ? root.i18nObj.tr("Details…") : "Details…"
                    onClicked: root.openDetailFor(null)
                }
                PlasmaComponents.Button {
                    text: root.i18nObj ? root.i18nObj.tr("Refresh") : "Refresh"
                    icon.name: "view-refresh"
                    onClicked: {
                        if (root.usageController) root.usageController.refreshAll()
                    }
                }
                PlasmaComponents.Button {
                    text: root.i18nObj ? root.i18nObj.tr("Configure…") : "Configure…"
                    icon.name: "configure"
                    onClicked: {
                        try { Plasmoid.internalAction("configure").trigger() } catch (e) {}
                    }
                }
            }
            Item { Layout.fillHeight: true }
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
            var wins = QC.primaryWindows(p)
            for (var j = 0; j < wins.length; j++) {
                var cd = QC.formatCountdown(wins[j].resetAtMs, root.nowMs)
                parts.push(QC.displayWindowLabel(wins[j]) + " " + Math.round(wins[j].usagePercent) + "%"
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
