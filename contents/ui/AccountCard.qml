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

    readonly property int contentFontPixelSize: Math.round(
        (Kirigami.Theme.smallFont.pixelSize + Kirigami.Theme.defaultFont.pixelSize) / 2)

    signal detailRequested(var profile)
    signal refreshRequested(var profile)

    readonly property var quotaRows: QC.visibleWindows(profile)
    // Any in-flight fetch (refresh or first load)
    readonly property bool refreshing: !!(profile && profile.loading)
    // First load only — no windows yet. Never collapse existing rows while refreshing.
    readonly property bool initialLoad: refreshing
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

        // Header: name · inline error · banked · refresh/spinner · detail
        RowLayout {
            id: headerRow
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            // This slot absorbs width pressure before the always-allocated controls do.
            Item {
                id: headerTextSlot
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: Math.max(nameLabel.implicitHeight, errorLabel.implicitHeight)

                PlasmaComponents.Label {
                    id: nameLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(
                        implicitWidth,
                        headerTextSlot.width * (cardRoot.hasError ? 0.4 : 1))
                    text: cardRoot.title
                    font.bold: true
                    font.pixelSize: cardRoot.contentFontPixelSize
                    color: Kirigami.Theme.textColor
                    elide: Text.ElideRight

                    HoverHandler { id: nameHover }
                    QQC2.ToolTip {
                        visible: nameHover.hovered
                        text: {
                            var bits = [cardRoot.title]
                            if (profile && profile.planName) bits.push(profile.planName)
                            if (profile && profile.configDir) bits.push(profile.configDir)
                            if (cardRoot.refreshing) bits.push("Refreshing…")
                            return bits.join("\n")
                        }
                    }
                }

                PlasmaComponents.Label {
                    id: errorLabel
                    anchors.left: nameLabel.right
                    anchors.leftMargin: visible ? Kirigami.Units.smallSpacing : 0
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: cardRoot.hasError
                    text: cardRoot.hasError ? ("⚠ " + cardRoot.profile.error) : ""
                    textFormat: Text.PlainText
                    font.pixelSize: cardRoot.contentFontPixelSize
                    color: Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    Accessible.name: cardRoot.hasError
                        ? ("Error: " + cardRoot.profile.error) : ""
                    Accessible.role: Accessible.StaticText
                    Accessible.ignored: !cardRoot.hasError

                    HoverHandler { id: errorHover }
                    QQC2.ToolTip {
                        visible: errorHover.hovered && cardRoot.hasError
                        text: cardRoot.hasError ? cardRoot.profile.error : ""
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

            // Always-allocated slot: refresh control idle, spinner while this profile loads
            Item {
                id: refreshSlot
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.alignment: Qt.AlignVCenter

                PlasmaComponents.BusyIndicator {
                    anchors.fill: parent
                    visible: cardRoot.refreshing
                    running: cardRoot.refreshing
                    Accessible.name: "Refreshing"
                    Accessible.ignored: !cardRoot.refreshing
                }

                Kirigami.Icon {
                    anchors.fill: parent
                    source: "view-refresh"
                    opacity: refreshMouse.containsMouse ? 1 : 0.55
                    visible: !cardRoot.refreshing
                    color: Kirigami.Theme.textColor
                    Accessible.name: "Refresh"
                    Accessible.role: Accessible.Button
                    Accessible.ignored: cardRoot.refreshing
                }

                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    anchors.margins: -Kirigami.Units.smallSpacing / 2
                    enabled: !cardRoot.refreshing && !!cardRoot.profile
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (cardRoot.profile)
                            cardRoot.refreshRequested(cardRoot.profile)
                    }
                }
                QQC2.ToolTip {
                    visible: refreshMouse.containsMouse && !cardRoot.refreshing
                    text: "Refresh"
                }
            }

            // B022: never put MouseArea as a bare RowLayout child (zero size).
            // Wrap the "⋯" control in an Item with real implicit size for hit testing.
            Item {
                id: detailBtn
                implicitWidth: Math.max(Kirigami.Units.iconSizes.small,
                                        detailDots.implicitWidth + Kirigami.Units.smallSpacing * 2)
                implicitHeight: Math.max(Kirigami.Units.iconSizes.small,
                                         detailDots.implicitHeight + Kirigami.Units.smallSpacing * 2)
                Layout.preferredWidth: implicitWidth
                Layout.preferredHeight: implicitHeight
                Layout.alignment: Qt.AlignVCenter
                Accessible.name: "Details"
                Accessible.role: Accessible.Button
                Accessible.onPressAction: cardRoot.detailRequested(cardRoot.profile)

                PlasmaComponents.Label {
                    id: detailDots
                    anchors.centerIn: parent
                    text: "⋯"
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: detailHover.hovered
                           ? Kirigami.Theme.textColor
                           : Kirigami.Theme.disabledTextColor
                }

                HoverHandler { id: detailHover }
                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: cardRoot.detailRequested(cardRoot.profile)
                }
                QQC2.ToolTip {
                    visible: detailHover.hovered
                    text: "Details"
                }
            }
        }

        // Selected quota rows or first-load skeleton (stale rows kept while refreshing)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)
            visible: !hasError || (quotaRows && quotaRows.length)

            Repeater {
                model: {
                    if (quotaRows && quotaRows.length > 0)
                        return quotaRows
                    // First load / empty: two skeleton rows (not on mid-refresh with data)
                    if (cardRoot.initialLoad || (profile && !profile.lastFetchMs && !hasError))
                        return [null, null]
                    return []
                }
                QuotaRow {
                    required property var modelData
                    Layout.fillWidth: true
                    windowData: modelData
                    nowMs: cardRoot.nowMs
                    mode: modelData ? "data" : "skeleton"
                    compact: true
                    textPixelSize: cardRoot.contentFontPixelSize
                    // Slight dim while refreshing existing data
                    opacity: (modelData && cardRoot.refreshing) ? 0.75 : 1
                    colorMode: modelData
                        ? QC.colorModeForWindow(modelData, sessionColorMode, weeklyColorMode)
                        : sessionColorMode
                }
            }
        }
    }
}
