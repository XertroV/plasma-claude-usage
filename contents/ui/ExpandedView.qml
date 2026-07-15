import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// Self-contained expanded UI. Pass plain data via props (no sibling ids from main).
// Body scrolls; footer (Updated / Refresh) stays pinned so large profile lists
// never overflow the plasmoidviewer / popup window.
ColumnLayout {
    id: expandedRoot

    property var profiles: []
    property int dataEpoch: 0
    property double nowMs: 0
    property string lastGlobalUpdate: ""
    property int profilesDone: 0
    property int profilesTotal: 0
    property bool isLoading: false
    property var i18n: null
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true
    property var expandedSections: ({})

    signal refreshRequested()
    signal rediscoverRequested()

    spacing: Kirigami.Units.smallSpacing
    clip: true

    function tr(t) { return i18n ? i18n.tr(t) : t }

    function sectionKey(profileId) { return profileId + "_extras" }
    function isExpanded(profileId) { return !!expandedSections[sectionKey(profileId)] }
    function toggleSection(profileId) {
        var k = sectionKey(profileId)
        var copy = {}
        for (var p in expandedSections) copy[p] = expandedSections[p]
        copy[k] = !copy[k]
        expandedSections = copy
    }

    function primaryWindows(profile) {
        var wins = (profile && profile.windows) ? profile.windows : []
        var prim = []
        for (var i = 0; i < wins.length; i++) {
            var w = wins[i]
            if (!w || w.visible === false) continue
            if (w.role === "primary" || w.role === "" || w.role === undefined)
                prim.push(w)
        }
        if (prim.length === 0) {
            for (var j = 0; j < wins.length; j++) {
                if (wins[j] && wins[j].visible !== false)
                    prim.push(wins[j])
            }
        }
        return prim
    }

    function extraWindows(profile) {
        var wins = (profile && profile.windows) ? profile.windows : []
        var out = []
        for (var i = 0; i < wins.length; i++) {
            if (wins[i] && wins[i].role === "extra")
                out.push(wins[i])
        }
        return out
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        visible: isLoading && profilesTotal > 0 && profilesDone < profilesTotal
        text: tr("Loading") + " " + profilesDone + "/" + profilesTotal
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        visible: !isLoading && (!profiles || profiles.length === 0)
        text: tr("No profiles")
        color: Kirigami.Theme.disabledTextColor
    }

    PlasmaComponents.ScrollView {
        id: bodyScroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6
        clip: true
        // Avoid horizontal overflow when popup/viewer is narrow or wide
        contentWidth: availableWidth

        ColumnLayout {
            // Bind width to viewport so RowLayouts wrap/elide instead of growing out
            width: bodyScroll.availableWidth
            spacing: Kirigami.Units.mediumSpacing

            Repeater {
                model: {
                    var _ = expandedRoot.dataEpoch
                    return expandedRoot.profiles || []
                }

                ColumnLayout {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    visible: modelData && modelData.enabled !== false

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: {
                                var name = modelData.displayName || modelData.id || "?"
                                var plan = modelData.planName || ""
                                if (plan && plan !== name && name.indexOf(plan) < 0)
                                    return name + " · " + plan
                                return name
                            }
                            font.bold: true
                        }
                        PlasmaComponents.Label {
                            visible: !!modelData.loading
                            text: tr("Loading...")
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            color: Kirigami.Theme.disabledTextColor
                        }
                        PlasmaComponents.Label {
                            visible: showBankedBadge && modelData.bankedResets > 0
                            text: "↻" + modelData.bankedResets
                            color: Kirigami.Theme.highlightColor
                        }
                    }

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: modelData.error && modelData.error !== ""
                        text: "⚠ " + modelData.error
                        color: Kirigami.Theme.negativeTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        elide: Text.ElideRight
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: !!modelData.loading && !(modelData.error)
                                 && !(modelData.windows && modelData.windows.length)
                        text: expandedRoot.profilesTotal > 0
                              ? (tr("Loading") + " " + expandedRoot.profilesDone + "/" + expandedRoot.profilesTotal)
                              : tr("Fetching usage…")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.disabledTextColor
                    }

                    Repeater {
                        model: expandedRoot.primaryWindows(modelData)
                        QuotaSlot {
                            required property var modelData
                            Layout.fillWidth: true
                            windowData: modelData
                            nowMs: expandedRoot.nowMs
                            colorMode: (modelData.id === "session" || (modelData.id && String(modelData.id).indexOf("5h") === 0))
                                ? sessionColorMode : weeklyColorMode
                            compact: false
                        }
                    }

                    MouseArea {
                        Layout.fillWidth: true
                        Layout.preferredHeight: extrasHeader.implicitHeight
                        cursorShape: Qt.PointingHandCursor
                        onClicked: expandedRoot.toggleSection(modelData.id)
                        visible: expandedRoot.extraWindows(modelData).length > 0
                        PlasmaComponents.Label {
                            id: extrasHeader
                            text: (expandedRoot.isExpanded(modelData.id) ? "▾ " : "▸ ") + tr("Extra limits")
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        }
                    }

                    Repeater {
                        model: expandedRoot.isExpanded(modelData.id)
                               ? expandedRoot.extraWindows(modelData) : []
                        RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            PlasmaComponents.Label {
                                text: modelData.label || ""
                                Layout.preferredWidth: Math.min(120, parent.width * 0.35)
                                elide: Text.ElideRight
                            }
                            PaceBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 8
                                Layout.minimumWidth: 48
                                Layout.maximumWidth: 200
                                usagePercent: modelData.usagePercent || 0
                                timePercent: modelData.timePercent || 0
                                colorMode: weeklyColorMode
                                compact: false
                                windowData: modelData
                            }
                            PlasmaComponents.Label {
                                text: Math.round(modelData.usagePercent || 0) + "%"
                                Layout.preferredWidth: 40
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Kirigami.Theme.disabledTextColor
                        opacity: 0.2
                    }
                }
            }
        }
    }

    // Pinned footer — always visible, never scrolled away
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        PlasmaComponents.Label {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: {
                if (lastGlobalUpdate && lastGlobalUpdate !== "")
                    return tr("Updated:") + " " + lastGlobalUpdate
                if (profilesTotal > 0)
                    return tr("Loading") + " " + profilesDone + "/" + profilesTotal
                if (isLoading)
                    return tr("Loading...")
                return tr("Updated:") + " —"
            }
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }
        PlasmaComponents.Button {
            icon.name: "view-refresh"
            text: tr("Refresh")
            onClicked: expandedRoot.refreshRequested()
        }
        PlasmaComponents.Button {
            icon.name: "system-search"
            text: tr("Rediscover")
            onClicked: expandedRoot.rediscoverRequested()
        }
    }
}
