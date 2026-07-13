import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

RowLayout {
    id: slotRoot

    required property var windowData
    required property int nowMs
    property string colorMode: "capacity"
    property bool compact: true

    spacing: Kirigami.Units.smallSpacing

    readonly property real barWidth: compact ? 36 : 80
    readonly property color fillColor: QC.windowPaceColor(windowData, colorMode, Kirigami.Theme)

    Rectangle {
        Layout.preferredWidth: barWidth
        Layout.preferredHeight: compact ? 5 : 8
        radius: 2
        color: Kirigami.Theme.backgroundColor
        border.color: Kirigami.Theme.disabledTextColor
        border.width: 1
        Rectangle {
            width: parent.width * Math.min((windowData.usagePercent || 0) / 100, 1)
            height: parent.height
            radius: 2
            color: slotRoot.fillColor
        }
    }

    PlasmaComponents.Label {
        text: Math.round(windowData.usagePercent || 0) + "%"
        font.pixelSize: compact ? Kirigami.Theme.smallFont.pixelSize : Kirigami.Theme.defaultFont.pixelSize
        font.bold: true
        color: slotRoot.fillColor
    }

    PlasmaComponents.Label {
        visible: windowData.resetAtMs > 0
        text: QC.formatCountdown(windowData.resetAtMs, nowMs)
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
    }
}