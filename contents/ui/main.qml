import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

PlasmoidItem {
    id: root

    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    ProfileController {
        id: controller
        visible: false
        width: 0
        height: 0
        plasmoid: Plasmoid
        i18n: i18n
        Component.onCompleted: {
            bootstrapLegacyProfiles()
            if (profiles.length === 0 && Plasmoid.configuration.discoverOnLoad !== false)
                discoverProfiles()
        }
    }

    readonly property string legacyPanelTitle: {
        var dn = Plasmoid.configuration.displayName || ""
        if (dn) return dn
        if (controller.profiles.length === 1)
            return controller.profiles[0].displayName || controller.profiles[0].id || ""
        return ""
    }

    compactRepresentation: Item {
        Layout.minimumWidth: Math.max(usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2,
            Kirigami.Units.gridUnit * 4)
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: Math.max(Kirigami.Units.iconSizes.medium, usageRow.implicitHeight)

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg")
            }

            PanelView {
                controller: controller
                sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
            }

            PlasmaComponents.Label {
                visible: usageRow.implicitWidth < Kirigami.Units.gridUnit * 3
                    && (controller.discovering || legacyPanelTitle !== "")
                text: controller.discovering ? "…" : legacyPanelTitle
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.textColor
            }
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: Math.max(Kirigami.Units.gridUnit * 14, expandedColumn.implicitHeight)

        ColumnLayout {
            id: expandedColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing

            PlasmaComponents.Label {
                text: i18n.tr("Usage quotas")
                font.bold: true
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
            }

            ExpandedView {
                Layout.fillWidth: true
                controller: controller
                i18n: i18n
                sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity"
                weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
                showBankedBadge: Plasmoid.configuration.showBankedBadge !== false
            }
        }
    }

    function tooltipText() {
        if (!controller) return i18n.tr("Loading...")
        var lines = []
        for (var i = 0; i < controller.profiles.length; i++) {
            var p = controller.profiles[i]
            if (!p.enabled) continue
            var parts = []
            var wins = p.windows || []
            for (var j = 0; j < wins.length; j++) {
                if (!wins[j].visible) continue
                var cd = QC.formatCountdown(wins[j].resetAtMs, controller.nowMs)
                parts.push(wins[j].label + " " + Math.round(wins[j].usagePercent) + "%"
                    + (cd ? " (" + cd + ")" : ""))
            }
            if (p.bankedResets > 0) parts.push("↻" + p.bankedResets)
            if (parts.length) lines.push((p.displayName || p.id) + ": " + parts.join(" | "))
            else if (p.error) lines.push((p.displayName || p.id) + ": " + p.error)
        }
        return lines.length ? lines.join("\n") : i18n.tr("Loading...")
    }

    Plasmoid.icon: "claude-usage"
    toolTipMainText: i18n.tr("AI Usage")
    toolTipSubText: tooltipText()

    Component.onCompleted: {
        console.log("Claude Usage: multi-profile widget loaded")
    }
}