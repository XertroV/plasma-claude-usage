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
    // Mirrored for fullRepresentation / CardsView (sibling ids do not resolve there)
    property int dataEpoch: 0
    property double nowMs: Date.now()
    property string lastGlobalUpdate: ""
    property alias usageController: controller
    property alias i18nObj: i18n
    // Ignore config signals during bootstrap so we don't double-discover (B003)
    property bool configWatchReady: false

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
            // Defer watching until after initial config property binds settle
            Qt.callLater(function() { root.configWatchReady = true })
        }
        onProfilesChanged: {
            root.syncCompactFromController()
            root.syncDetailProfileFromList()
        }
        onDataEpochChanged: {
            root.syncCompactFromController()
            root.syncDetailProfileFromList()
        }
        // B027: clock tick must NOT rebuild profileList (Repeater model → tooltip flicker).
        // Countdown / pace UI binds to root.nowMs directly.
        onNowMsChanged: root.nowMs = controller.nowMs
        onDiscoveringChanged: root.syncCompactFromController()
        onLastGlobalUpdateChanged: root.syncCompactFromController()
    }

    // B003: Apply in KCM must re-bind multi-profile settings without plasmashell restart.
    // Coalesce multi-key Apply storms: rediscover > membership > soft.
    property bool configDirtyRediscover: false
    property bool configDirtyMembership: false
    property bool configDirtySoft: false

    Connections {
        target: Plasmoid.configuration
        enabled: root.configWatchReady

        function onMultiProfileModeChanged() { root.markConfigDirty("rediscover") }
        function onCredentialsPathChanged() { root.markConfigDirty("rediscover") }
        function onProviderChanged() { root.markConfigDirty("rediscover") }
        function onOpencodeSubProviderChanged() { root.markConfigDirty("rediscover") }
        function onCustomProfilesJsonChanged() { root.markConfigDirty("rediscover") }
        function onEnabledProfilesJsonChanged() { root.markConfigDirty("membership") }
        function onProfileDisplayNamesJsonChanged() { root.markConfigDirty("soft") }
        function onVisibleWindowsJsonChanged() { root.markConfigDirty("soft") }
        function onDisplayNameChanged() { root.markConfigDirty("soft") }
    }

    Timer {
        id: configCoalesceTimer
        interval: 50
        repeat: false
        onTriggered: root.flushConfigDirty()
    }

    function markConfigDirty(kind) {
        if (!configWatchReady) return
        if (kind === "rediscover") configDirtyRediscover = true
        else if (kind === "membership") configDirtyMembership = true
        else configDirtySoft = true
        configCoalesceTimer.restart()
    }

    function flushConfigDirty() {
        if (!controller || !configWatchReady) return
        var opts = {}
        if (configDirtyRediscover)
            opts = { rediscover: true }
        else if (configDirtyMembership)
            opts = { membership: true }
        // else soft {}
        configDirtyRediscover = false
        configDirtyMembership = false
        configDirtySoft = false
        controller.reapplyConfig(opts)
        root.syncCompactFromController()
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
            // All hidden (list non-empty, zero enabled) is an idle empty state, not loading (B032).
            var hasRows = list.length > 0
            compactName = Plasmoid.configuration.displayName
                || defaultProviderLabel()
                || (hasRows ? i18n.tr("Hidden") : i18n.tr("Loading..."))
            errorMsg = ""
            sessionUsagePercent = 0
            weeklyUsagePercent = 0
            sessionTimePercent = 0
            weeklyTimePercent = 0
            hasSessionWindow = false
            hasWeeklyWindow = false
            bankedResets = 0
            isLoading = !!controller.discovering || (!hasRows && profilesTotal === 0)
            loadingCountText = controller.discovering
                ? (profilesTotal > 0 ? (profilesDone + "/" + profilesTotal) : "…")
                : ""
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
            // Prefer a visible account; fall back to any (incl. hidden) so unhide works (B032)
            for (var i = 0; i < list.length; i++) {
                if (list[i] && list[i].enabled !== false) {
                    profile = list[i]
                    break
                }
            }
            if (!profile) {
                for (var j = 0; j < list.length; j++) {
                    if (list[j] && list[j].id) {
                        profile = list[j]
                        break
                    }
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

    /** Re-bind open detail window to the live profile row after membership changes (B032). */
    function syncDetailProfileFromList() {
        if (!detailWindow.visible || !detailWindow.profile || !detailWindow.profile.id)
            return
        var id = detailWindow.profile.id
        var list = root.profileList || []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].id === id) {
                detailWindow.profile = list[i]
                detailWindow.syncHiddenFromProfile()
                return
            }
        }
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
            // Manual refresh of the open account (works even when Hidden) (B032)
            if (!root.usageController) return
            if (detailWindow.profile && detailWindow.profile.id)
                root.usageController.refreshProfile(detailWindow.profile.id)
            else
                root.usageController.refreshAll()
        }
        onConfigureRequested: {
            try {
                Plasmoid.internalAction("configure").trigger()
            } catch (e) {
                console.log("Claude Usage: configure action failed", e)
            }
        }
        onHiddenToggled: function(profileId, hidden) {
            if (root.usageController)
                root.usageController.setProfileHidden(profileId, hidden)
        }
    }

    // Cards are the product for both panel (compact) and main/windowed (full).
    preferredRepresentation: fullRepresentation
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 6

    compactRepresentation: Item {
        id: compactRoot

        implicitWidth: Math.max(Kirigami.Units.gridUnit * 14, cardsCompact.implicitWidth + Kirigami.Units.smallSpacing * 2)
        implicitHeight: Math.max(Kirigami.Units.iconSizes.medium, cardsCompact.implicitHeight + Kirigami.Units.smallSpacing)

        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight

        CardsView {
            id: cardsCompact
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing / 2
            profiles: root.profileList
            dataEpoch: root.dataEpoch
            nowMs: root.nowMs
            sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
            weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
            showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
            isLoading: root.isLoading
            loadingText: root.loadingCountText
            maxCards: 8
            cardMinWidth: Kirigami.Units.gridUnit * 10
            fillWidth: true
            i18n: root.i18nObj
            onDetailRequested: function(p) { root.openDetailFor(p) }
        }
    }

    // Main widget surface (plasmawindowed, desktop widget, expanded): card list
    fullRepresentation: Item {
        id: fullRoot

        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10
        Layout.preferredWidth: Kirigami.Units.gridUnit * 28
        // Prefer content-sized height; avoid a huge empty body when few card rows
        Layout.preferredHeight: Math.min(
            Kirigami.Units.gridUnit * 28,
            Math.max(Kirigami.Units.gridUnit * 12,
                     cardsFull.implicitHeight + Kirigami.Units.gridUnit * 6))
        Layout.maximumWidth: Kirigami.Units.gridUnit * 48
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    source: Qt.resolvedUrl("../icons/claude.svg")
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: root.i18nObj ? root.i18nObj.tr("AI Usage") : "AI Usage"
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.1
                    elide: Text.ElideRight
                }
                PlasmaComponents.Label {
                    visible: root.isLoading
                    text: root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1))
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: root.i18nObj ? root.i18nObj.tr("Refresh") : "Refresh"
                    onClicked: {
                        if (root.usageController) root.usageController.refreshAll()
                    }
                }
            }

            PlasmaComponents.ScrollView {
                id: fullScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth

                CardsView {
                    id: cardsFull
                    width: fullScroll.availableWidth
                    // Height follows flow content so ScrollView can scroll when many cards
                    height: Math.max(implicitHeight, fullScroll.availableHeight > 0
                                     ? fullScroll.availableHeight : implicitHeight)
                    profiles: root.profileList
                    dataEpoch: root.dataEpoch
                    nowMs: root.nowMs
                    sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                    weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                    showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
                    isLoading: root.isLoading
                    loadingText: ""
                    maxCards: 12
                    cardMinWidth: Kirigami.Units.gridUnit * 11
                    fillWidth: true
                    i18n: root.i18nObj
                    onDetailRequested: function(p) { root.openDetailFor(p) }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        if (root.lastGlobalUpdate && root.lastGlobalUpdate !== "")
                            return (root.i18nObj ? root.i18nObj.tr("Updated:") : "Updated:") + " " + root.lastGlobalUpdate
                        if (root.isLoading)
                            return root.i18nObj ? root.i18nObj.tr("Loading...") : "Loading..."
                        return ""
                    }
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                PlasmaComponents.Button {
                    icon.name: "configure"
                    text: root.i18nObj ? root.i18nObj.tr("Configure…") : "Configure…"
                    onClicked: {
                        try { Plasmoid.internalAction("configure").trigger() } catch (e) {}
                    }
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
