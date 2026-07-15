import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// Single quota line: label | bar | % | countdown
// modes: "data" | "skeleton"
RowLayout {
    id: rowRoot

    property var windowData: null
    property double nowMs: Date.now()
    property string colorMode: "capacity"
    property string mode: "data"   // data | skeleton
    property bool compact: true

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    readonly property bool isSkeleton: mode === "skeleton" || !windowData
    readonly property string periodLabel: isSkeleton ? "··" : QC.displayWindowLabel(windowData)
    readonly property real usagePct: windowData ? (windowData.usagePercent || 0) : 0
    readonly property real timePct: windowData ? (windowData.timePercent || 0) : 0
    readonly property color fillColor: isSkeleton
        ? Kirigami.Theme.disabledTextColor
        : QC.windowPaceColor(windowData, colorMode, Kirigami.Theme)

    PlasmaComponents.Label {
        text: rowRoot.periodLabel
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        font.bold: true
        color: isSkeleton ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.disabledTextColor
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
        Layout.maximumWidth: Kirigami.Units.gridUnit * 4
        elide: Text.ElideRight
    }

    PaceBar {
        Layout.fillWidth: true
        Layout.preferredWidth: compact ? Kirigami.Units.gridUnit * 3 : Kirigami.Units.gridUnit * 6
        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
        Layout.preferredHeight: compact ? 6 : 10
        usagePercent: isSkeleton ? 0 : rowRoot.usagePct
        timePercent: isSkeleton ? 0 : rowRoot.timePct
        colorMode: rowRoot.colorMode
        compact: rowRoot.compact
        windowData: isSkeleton ? null : rowRoot.windowData
        opacity: isSkeleton ? 0.45 : 1
    }

    PlasmaComponents.Label {
        text: isSkeleton ? "··" : (Math.round(rowRoot.usagePct) + "%")
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        font.bold: !isSkeleton
        color: isSkeleton ? Kirigami.Theme.disabledTextColor : rowRoot.fillColor
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
        horizontalAlignment: Text.AlignRight
    }

    PlasmaComponents.Label {
        text: {
            if (isSkeleton) return "—"
            if (!windowData || !windowData.resetAtMs) return ""
            return QC.formatCountdown(windowData.resetAtMs, nowMs)
        }
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
        Layout.maximumWidth: Kirigami.Units.gridUnit * 5
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
    }

    HoverHandler { id: rowHover }
    PlasmaComponents.ToolTip {
        visible: rowHover.hovered && !isSkeleton && windowData
        delay: Kirigami.Units.toolTipDelay
        text: {
            if (!windowData) return ""
            var parts = [QC.displayWindowLabel(windowData),
                         Math.round(windowData.usagePercent || 0) + "%"]
            var cd = QC.formatCountdown(windowData.resetAtMs, nowMs)
            if (cd) parts.push(cd)
            if (windowData.tooltipExtra) parts.push(windowData.tooltipExtra)
            return parts.join(" · ")
        }
    }
}
