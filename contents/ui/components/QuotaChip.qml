import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../js/QuotaCommon.js" as QC

RowLayout {
    id: chipRoot

    required property var windowData
    required property int nowMs
    property string colorMode: "capacity"

    spacing: 2

    readonly property color dotColor: QC.windowPaceColor(windowData, colorMode, Kirigami.Theme)

    Rectangle {
        Layout.preferredWidth: 6
        Layout.preferredHeight: 6
        radius: 3
        color: chipRoot.dotColor
    }

    PlasmaComponents.Label {
        text: (windowData.label || "") + " " + Math.round(windowData.usagePercent || 0) + "%"
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.textColor
    }

    MouseArea {
        id: chipMouse
        anchors.fill: parent
        hoverEnabled: true
    }

    QQC2.ToolTip {
        visible: chipMouse.containsMouse
        text: {
            var cd = QC.formatCountdown(windowData.resetAtMs, nowMs)
            return (windowData.label || "") + ": " + Math.round(windowData.usagePercent || 0) + "%"
                + (cd ? " · " + cd : "")
        }
    }
}