import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// Single quota line: label | bar | % | countdown
// modes: "data" | "skeleton"
// Presentation policy (label, colorMode) comes from presentationRow;
// this row owns only time/theme rendering.
RowLayout {
    id: rowRoot

    property var presentationRow: null
    property double nowMs: Date.now()
    property string mode: "data"   // data | skeleton
    property bool compact: true
    property int textPixelSize: compact
        ? Math.round((Kirigami.Theme.smallFont.pixelSize
                      + Kirigami.Theme.defaultFont.pixelSize) / 2)
        : Kirigami.Theme.defaultFont.pixelSize

    readonly property var windowData: presentationRow
            ? presentationRow.windowData : null
    readonly property string colorMode: presentationRow
            ? presentationRow.colorMode : "capacity"
    readonly property bool isSkeleton: mode === "skeleton" || !windowData
    readonly property string periodLabel: isSkeleton
            ? "··" : (presentationRow.label || "")

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    // Fixed text columns (same on every row) so pace bars share one width and columns align.
    // Keep text slots lean; the bar is the only fillWidth child.
    readonly property real periodColWidth: compact
            ? Kirigami.Units.gridUnit * 2
            : Kirigami.Units.gridUnit * 2.5
    readonly property real percentColWidth: Kirigami.Units.gridUnit * 1.6
    readonly property real countdownColWidth: compact
            ? Kirigami.Units.gridUnit * 2.5
            : Kirigami.Units.gridUnit * 3

    readonly property real usagePct: windowData ? (windowData.usagePercent || 0) : 0
    // B027: derive from nowMs so pace bars tick without rebuilding window/profile models
    readonly property real timePct: {
        var _ = nowMs
        if (isSkeleton || !windowData) return 0
        return QC.computeTimePercent(windowData, nowMs)
    }
    readonly property color fillColor: {
        var _ = nowMs
        if (isSkeleton) return Kirigami.Theme.disabledTextColor
        return QC.windowPaceColor(windowData, colorMode, Kirigami.Theme, nowMs)
    }

    PlasmaComponents.Label {
        text: rowRoot.periodLabel
        font.pixelSize: rowRoot.textPixelSize
        font.bold: true
        color: isSkeleton
               ? Kirigami.Theme.disabledTextColor
               : Kirigami.Theme.textColor
        Layout.preferredWidth: rowRoot.periodColWidth
        Layout.minimumWidth: rowRoot.periodColWidth
        Layout.maximumWidth: rowRoot.periodColWidth
        Layout.fillWidth: false
        elide: Text.ElideRight
    }

    PaceBar {
        // Sole expanding column — equal leftover width on every row of the card.
        Layout.fillWidth: true
        Layout.preferredWidth: 0
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
        font.pixelSize: rowRoot.textPixelSize
        font.bold: !isSkeleton
        color: isSkeleton ? Kirigami.Theme.disabledTextColor : rowRoot.fillColor
        Layout.preferredWidth: rowRoot.percentColWidth
        Layout.minimumWidth: rowRoot.percentColWidth
        Layout.maximumWidth: rowRoot.percentColWidth
        Layout.fillWidth: false
        horizontalAlignment: Text.AlignRight
    }

    PlasmaComponents.Label {
        text: {
            if (isSkeleton) return "—"
            if (!windowData || !windowData.resetAtMs) return ""
            return QC.formatCountdown(windowData.resetAtMs, nowMs)
        }
        font.pixelSize: rowRoot.textPixelSize
        color: Kirigami.Theme.disabledTextColor
        // Fixed thin countdown slot: short text sits right-aligned; long text elides.
        Layout.preferredWidth: rowRoot.countdownColWidth
        Layout.minimumWidth: rowRoot.countdownColWidth
        Layout.maximumWidth: rowRoot.countdownColWidth
        Layout.fillWidth: false
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
    }

    HoverHandler { id: rowHover }
    PlasmaComponents.ToolTip {
        visible: rowHover.hovered && !isSkeleton && windowData
        delay: Kirigami.Units.toolTipDelay
        text: {
            if (!windowData) return ""
            var parts = [rowRoot.periodLabel,
                         Math.round(windowData.usagePercent || 0) + "%"]
            var cd = QC.formatCountdown(windowData.resetAtMs, nowMs)
            if (cd) parts.push(cd)
            if (windowData.tooltipExtra) parts.push(windowData.tooltipExtra)
            return parts.join(" · ")
        }
    }
}
