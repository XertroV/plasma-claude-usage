import QtQuick
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// Multi-part usage bar with pace context:
//   [ under-pace fill | over-pace fill | empty ]
//                    ^ time marker (elapsed fraction of the window)
// Under pace  → usage stays left of the marker
// Over pace   → amber/red segment past the marker
// Soft green wash between usage and marker when under pace (headroom)
Item {
    id: barRoot

    property real usagePercent: 0
    property real timePercent: 0
    property string colorMode: "capacity"
    property bool compact: false
    /** Optional full window object for QC.windowPaceColor */
    property var windowData: null

    readonly property real usage: Math.max(0, Math.min(100, Number(usagePercent) || 0))
    readonly property real timeP: Math.max(0, Math.min(100, Number(timePercent) || 0))
    readonly property bool hasPace: timeP > 0.5
    readonly property real pace: hasPace ? (usage / Math.max(timeP, 1)) : 0

    readonly property color paceColor: windowData
        ? QC.windowPaceColor(windowData, colorMode, Kirigami.Theme)
        : Kirigami.Theme.positiveTextColor

    // Track
    Rectangle {
        id: track
        anchors.fill: parent
        radius: compact ? 2 : 3
        color: Kirigami.Theme.backgroundColor
        border.color: Kirigami.Theme.disabledTextColor
        border.width: 1
        clip: true

        // No time axis: solid usage fill
        Rectangle {
            visible: !barRoot.hasPace
            width: parent.width * (barRoot.usage / 100)
            height: parent.height
            radius: track.radius
            color: barRoot.paceColor
        }

        // 0 → min(usage, time): on-budget / under-pace portion
        Rectangle {
            visible: barRoot.hasPace
            width: parent.width * (Math.min(barRoot.usage, barRoot.timeP) / 100)
            height: parent.height
            radius: track.radius
            color: barRoot.paceColor
        }

        // time → usage: over-pace burn (ahead of schedule)
        Rectangle {
            visible: barRoot.hasPace && barRoot.usage > barRoot.timeP + 0.25
            x: parent.width * (barRoot.timeP / 100)
            width: parent.width * ((barRoot.usage - barRoot.timeP) / 100)
            height: parent.height
            color: barRoot.pace >= 2.0
                   ? Kirigami.Theme.negativeTextColor
                   : Kirigami.Theme.neutralTextColor
        }

        // usage → time: soft headroom when under pace
        Rectangle {
            visible: barRoot.hasPace && barRoot.usage + 0.25 < barRoot.timeP
            x: parent.width * (barRoot.usage / 100)
            width: parent.width * ((barRoot.timeP - barRoot.usage) / 100)
            height: parent.height
            color: Kirigami.Theme.positiveTextColor
            opacity: 0.2
        }
    }

    // Time marker (elapsed fraction of the quota window)
    Rectangle {
        visible: barRoot.hasPace
        x: Math.min(parent.width - 1,
                    Math.max(0, Math.round(parent.width * (barRoot.timeP / 100)) - (compact ? 0 : 1)))
        y: -1
        width: compact ? 1 : 2
        height: parent.height + 2
        radius: 1
        color: Kirigami.Theme.textColor
        opacity: 0.8
    }

    HoverHandler {
        id: hover
        enabled: !compact
    }

    PlasmaComponents.ToolTip {
        visible: hover.hovered
        delay: Kirigami.Units.toolTipDelay
        text: {
            if (!barRoot.hasPace)
                return Math.round(barRoot.usage) + "% used"
            var rel = barRoot.usage - barRoot.timeP
            var delta = (rel >= 0 ? "+" : "") + Math.round(rel) + "pp vs even pace"
            return Math.round(barRoot.usage) + "% used · "
                + Math.round(barRoot.timeP) + "% time elapsed\n"
                + barRoot.pace.toFixed(2) + "× pace · " + delta
        }
    }
}
