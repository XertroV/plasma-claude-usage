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

    function profilePrimaryWindows(profile) {
        var out = []
        if (!profile || !profile.windows) return out
        for (var i = 0; i < profile.windows.length; i++) {
            var w = profile.windows[i]
            if (w.visible && w.role === "primary") out.push(w)
        }
        return out
    }

    function windowColor(win, colorMode) {
        return QC.windowPaceColor(win, colorMode, Kirigami.Theme)
    }

    compactRepresentation: Item {
        Layout.minimumWidth: panelColumn.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: panelColumn.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: Math.max(Kirigami.Units.iconSizes.medium, panelColumn.implicitHeight)

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg")
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            ColumnLayout {
                id: panelColumn
                Layout.minimumWidth: Kirigami.Units.gridUnit * 5
                spacing: 1

                Repeater {
                    model: controller.profiles

                    RowLayout {
                        required property var modelData
                        readonly property var profile: modelData
                        readonly property var primaryWins: root.profilePrimaryWindows(profile)
                        spacing: Kirigami.Units.smallSpacing
                        visible: modelData.enabled !== false

                        PlasmaComponents.Label {
                            text: profile.error ? "⚠" : (profile.displayName || profile.id || "?")
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            color: profile.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                            Layout.preferredWidth: 72
                            elide: Text.ElideRight
                        }

                        Repeater {
                            model: primaryWins

                            RowLayout {
                                required property var modelData
                                required property int index
                                readonly property var win: modelData
                                spacing: Kirigami.Units.smallSpacing

                                Rectangle {
                                    Layout.preferredWidth: 36
                                    Layout.preferredHeight: 5
                                    radius: 2
                                    color: Kirigami.Theme.backgroundColor
                                    border.color: Kirigami.Theme.disabledTextColor
                                    border.width: 1
                                    Rectangle {
                                        width: parent.width * Math.min((win.usagePercent || 0) / 100, 1)
                                        height: parent.height
                                        radius: 2
                                        color: root.windowColor(win,
                                            index === 0 ? (Plasmoid.configuration.sessionColorMode || "capacity")
                                                        : (Plasmoid.configuration.weeklyColorMode || "efficiency"))
                                    }
                                }

                                PlasmaComponents.Label {
                                    text: Math.round(win.usagePercent || 0) + "%"
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    font.bold: true
                                    color: root.windowColor(win,
                                        index === 0 ? (Plasmoid.configuration.sessionColorMode || "capacity")
                                                    : (Plasmoid.configuration.weeklyColorMode || "efficiency"))
                                }

                                PlasmaComponents.Label {
                                    visible: win.resetAtMs > 0
                                    text: QC.formatCountdown(win.resetAtMs, controller.nowMs)
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    color: Kirigami.Theme.disabledTextColor
                                }

                                PlasmaComponents.Label {
                                    visible: index < primaryWins.length - 1
                                    text: "|"
                                    opacity: 0.4
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                }
                            }
                        }

                        PlasmaComponents.Label {
                            visible: profile.bankedResets > 0
                                    && Plasmoid.configuration.showBankedBadge !== false
                            text: "↻" + profile.bankedResets
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            color: Kirigami.Theme.highlightColor
                        }

                        PlasmaComponents.Label {
                            visible: profile.error !== ""
                            text: profile.error
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            color: Kirigami.Theme.negativeTextColor
                            elide: Text.ElideRight
                        }
                    }
                }

                PlasmaComponents.Label {
                    visible: controller.profiles.length === 0 || panelColumn.implicitWidth < 8
                    text: controller.discovering ? "…"
                        : (Plasmoid.configuration.displayName || i18n.tr("Loading..."))
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                    font.bold: true
                    color: Kirigami.Theme.textColor
                }
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