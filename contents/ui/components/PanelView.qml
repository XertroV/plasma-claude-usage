import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
ColumnLayout {
    id: panelRoot

    required property var controller
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true

    spacing: 2

    Repeater {
        model: controller ? controller.profiles : []
        ProviderRow {
            Layout.fillWidth: true
            profile: modelData
            nowMs: controller.nowMs
            sessionColorMode: panelRoot.sessionColorMode
            weeklyColorMode: panelRoot.weeklyColorMode
            showBankedBadge: panelRoot.showBankedBadge
            visible: modelData.enabled !== false
        }
    }

    PlasmaComponents.Label {
        visible: controller.discovering
        text: "…"
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
    }

    PlasmaComponents.Label {
        visible: !controller.discovering && controller.profiles.length === 0
        text: "No profiles"
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
    }
}