import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

RowLayout {
    id: slotRoot

    required property var windowData
    required property double nowMs
    property string colorMode: "capacity"
    property bool compact: true

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true
    clip: true

    readonly property real barWidth: compact ? 36 : 80
    readonly property color fillColor: QC.windowPaceColor(windowData, colorMode, Kirigami.Theme)
    readonly property real usagePct: windowData ? (windowData.usagePercent || 0) : 0
    readonly property real timePct: windowData ? (windowData.timePercent || 0) : 0

    PlasmaComponents.Label {
        visible: !compact && windowData && windowData.label
        text: windowData.label || ""
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
        elide: Text.ElideRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 3
        Layout.maximumWidth: Kirigami.Units.gridUnit * 5
    }

    PaceBar {
        Layout.preferredWidth: barWidth
        Layout.fillWidth: !compact
        Layout.minimumWidth: compact ? barWidth : 48
        Layout.maximumWidth: compact ? barWidth : 280
        Layout.preferredHeight: compact ? 6 : 10
        usagePercent: slotRoot.usagePct
        timePercent: slotRoot.timePct
        colorMode: slotRoot.colorMode
        compact: slotRoot.compact
        windowData: slotRoot.windowData
    }

    PlasmaComponents.Label {
        text: Math.round(slotRoot.usagePct) + "%"
        font.pixelSize: compact ? Kirigami.Theme.smallFont.pixelSize : Kirigami.Theme.defaultFont.pixelSize
        font.bold: true
        color: slotRoot.fillColor
        Layout.preferredWidth: compact ? implicitWidth : 40
    }

    // Pace delta vs even burn: e.g. "+12" when usage is 12pp ahead of time
    PlasmaComponents.Label {
        id: deltaLabel
        visible: !compact && slotRoot.timePct > 0.5
        text: {
            var d = slotRoot.usagePct - slotRoot.timePct
            if (Math.abs(d) < 0.5) return "≈"
            return (d > 0 ? "+" : "") + Math.round(d)
        }
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: {
            var d = slotRoot.usagePct - slotRoot.timePct
            if (d > 5) return Kirigami.Theme.negativeTextColor
            if (d < -5) return Kirigami.Theme.positiveTextColor
            return Kirigami.Theme.disabledTextColor
        }
        Layout.preferredWidth: 28
        horizontalAlignment: Text.AlignRight

        HoverHandler { id: deltaHover }
        PlasmaComponents.ToolTip {
            visible: deltaHover.hovered
            delay: Kirigami.Units.toolTipDelay
            text: "pp vs even pace (usage − time elapsed)"
        }
    }

    PlasmaComponents.Label {
        visible: windowData && windowData.resetAtMs > 0
        text: QC.formatCountdown(windowData.resetAtMs, nowMs)
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
        elide: Text.ElideRight
        Layout.maximumWidth: Kirigami.Units.gridUnit * 6
    }
}
