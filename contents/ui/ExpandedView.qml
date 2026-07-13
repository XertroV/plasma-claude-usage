import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC
ColumnLayout {
    id: expandedRoot

    property var controller: null
    property var i18n: null
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true
    property var expandedSections: ({})

    spacing: Kirigami.Units.mediumSpacing

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

    Repeater {
        model: controller ? controller.profiles : []

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: modelData.enabled !== false

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: modelData.displayName + (modelData.planName ? " · " + modelData.planName : "")
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Label {
                    visible: showBankedBadge && modelData.bankedResets > 0
                    text: "↻" + modelData.bankedResets
                    color: Kirigami.Theme.highlightColor
                }
            }

            PlasmaComponents.Label {
                visible: modelData.error !== ""
                text: "⚠ " + modelData.error
                color: Kirigami.Theme.negativeTextColor
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }

            Repeater {
                model: {
                    var wins = modelData.windows || []
                    var prim = []
                    for (var i = 0; i < wins.length; i++) {
                        if (wins[i].visible && wins[i].role === "primary") prim.push(wins[i])
                    }
                    return prim
                }
                QuotaSlot {
                    Layout.fillWidth: true
                    windowData: modelData
                    nowMs: controller ? controller.nowMs : 0
                    colorMode: (modelData.id === "session" || (modelData.id && modelData.id.indexOf("5h") === 0))
                        ? sessionColorMode : weeklyColorMode
                    compact: false
                }
            }

            MouseArea {
                Layout.fillWidth: true
                Layout.preferredHeight: extrasHeader.implicitHeight
                cursorShape: Qt.PointingHandCursor
                onClicked: expandedRoot.toggleSection(modelData.id)
                visible: {
                    var wins = modelData.windows || []
                    for (var i = 0; i < wins.length; i++) {
                        if (wins[i].role === "extra") return true
                    }
                    return false
                }
                PlasmaComponents.Label {
                    id: extrasHeader
                    text: (expandedRoot.isExpanded(modelData.id) ? "▾ " : "▸ ") + tr("Extra limits")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                }
            }

            Repeater {
                model: {
                    if (!expandedRoot.isExpanded(modelData.id)) return []
                    var wins = modelData.windows || []
                    var out = []
                    for (var i = 0; i < wins.length; i++) {
                        if (wins[i].role === "extra") out.push(wins[i])
                    }
                    return out
                }
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label { text: modelData.label; Layout.preferredWidth: 100 }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 80
                        height: 8
                        radius: 3
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min((modelData.usagePercent || 0) / 100, 1)
                            height: parent.height
                            radius: 3
                            color: QC.windowPaceColor(modelData, weeklyColorMode, Kirigami.Theme)
                        }
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

    RowLayout {
        Layout.fillWidth: true
        visible: !!controller
        PlasmaComponents.Label {
            text: controller && controller.lastGlobalUpdate !== ""
                ? tr("Updated:") + " " + controller.lastGlobalUpdate : tr("Loading...")
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }
        Item { Layout.fillWidth: true }
        PlasmaComponents.Button {
            icon.name: "view-refresh"
            text: tr("Refresh")
            onClicked: controller.refreshAll()
        }
        PlasmaComponents.Button {
            icon.name: "system-search"
            text: tr("Rediscover")
            onClicked: controller.discoverProfiles()
        }
    }
}