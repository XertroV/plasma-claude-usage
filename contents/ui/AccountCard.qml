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

        // Header: name · spinner · banked · detail  (spinner replaces the old "…" body line)
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
                        if (cardRoot.refreshing) bits.push("Refreshing…")
                        return bits.join("\n")
                    }
                }
            }

            // Always-allocated spinner slot so refresh never reflows the card
            PlasmaComponents.BusyIndicator {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.alignment: Qt.AlignVCenter
                opacity: cardRoot.refreshing ? 1 : 0
                running: cardRoot.refreshing
                Accessible.name: "Refreshing"
                Accessible.ignored: !cardRoot.refreshing
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

        // Primary quota rows or first-load skeleton (stale rows kept while refreshing)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)
            visible: !hasError || (primaries && primaries.length)

            Repeater {
                model: {
                    if (primaries && primaries.length > 0)
                        return primaries
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
