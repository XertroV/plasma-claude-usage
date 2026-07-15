import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// One profile/account card for the panel flow layout.
Rectangle {
    id: cardRoot

    property var profile: null
    property double nowMs: Date.now()
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true
    property int minWidth: Kirigami.Units.gridUnit * 11

    signal detailRequested(var profile)

    readonly property var primaries: QC.primaryWindows(profile)
    readonly property bool loading: !!(profile && profile.loading)
            && !(profile.windows && profile.windows.length)
    readonly property bool hasError: !!(profile && profile.error)
    readonly property string title: profile
            ? (profile.displayName || profile.id || "?") : "…"

    implicitWidth: Math.max(minWidth, contentCol.implicitWidth + Kirigami.Units.smallSpacing * 2)
    implicitHeight: contentCol.implicitHeight + Kirigami.Units.smallSpacing * 2
    width: implicitWidth
    height: implicitHeight

    radius: Kirigami.Units.smallSpacing
    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                   Kirigami.Theme.textColor.b, 0.06)
    border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                          Kirigami.Theme.textColor.b, 0.12)
    border.width: 1
    clip: true

    ColumnLayout {
        id: contentCol
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)

        // Header: name · plan tip · banked · detail
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: hasError ? ("⚠ " + cardRoot.title) : cardRoot.title
                font.bold: true
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: hasError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                elide: Text.ElideRight

                HoverHandler { id: nameHover }
                QQC2.ToolTip {
                    visible: nameHover.hovered
                    text: {
                        var bits = [cardRoot.title]
                        if (profile && profile.planName) bits.push(profile.planName)
                        if (profile && profile.configDir) bits.push(profile.configDir)
                        return bits.join("\n")
                    }
                }
            }

            PlasmaComponents.Label {
                visible: showBankedBadge && profile && profile.bankedResets > 0
                text: "↻" + profile.bankedResets
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.highlightColor
                HoverHandler { id: bankedHover }
                QQC2.ToolTip {
                    visible: bankedHover.hovered
                    text: profile.bankedResets + " banked reset(s)"
                }
            }

            PlasmaComponents.Label {
                text: "⋯"
                font.bold: true
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
                Accessible.name: "Details"
                MouseArea {
                    id: detailMouse
                    anchors.fill: parent
                    anchors.margins: -Kirigami.Units.smallSpacing
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cardRoot.detailRequested(cardRoot.profile)
                }
                QQC2.ToolTip {
                    visible: detailMouse.containsMouse
                    text: "Details"
                }
            }
        }

        // Error line
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: hasError && profile.error
            text: profile.error
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.negativeTextColor
            elide: Text.ElideRight
            wrapMode: Text.WordWrap
            maximumLineCount: 2
        }

        // Primary quota rows or skeleton
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)
            visible: !hasError || (primaries && primaries.length)

            Repeater {
                model: {
                    if (cardRoot.loading || (!primaries || primaries.length === 0)) {
                        // Two skeleton rows while loading / empty
                        if (cardRoot.loading || (profile && !profile.lastFetchMs && !hasError))
                            return [null, null]
                        return []
                    }
                    return primaries
                }
                QuotaRow {
                    required property var modelData
                    Layout.fillWidth: true
                    windowData: modelData
                    nowMs: cardRoot.nowMs
                    mode: modelData ? "data" : "skeleton"
                    compact: true
                    colorMode: modelData
                        ? QC.colorModeForWindow(modelData, sessionColorMode, weeklyColorMode)
                        : sessionColorMode
                }
            }
        }

        PlasmaComponents.Label {
            visible: loading && (!primaries || primaries.length === 0)
            text: "…"
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }
    }
}
