import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

RowLayout {
    id: rowRoot

    required property var profile
    required property double nowMs
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true

    spacing: Kirigami.Units.smallSpacing

    readonly property var primaryWindows: {
        var out = []
        if (!profile || !profile.windows) return out
        for (var i = 0; i < profile.windows.length; i++) {
            var w = profile.windows[i]
            if (w.visible && w.role === "primary") out.push(w)
        }
        return out
    }

    readonly property var extraWindows: {
        var out = []
        if (!profile || !profile.windows) return out
        for (var i = 0; i < profile.windows.length; i++) {
            var w = profile.windows[i]
            if (w.visible && w.role === "extra") out.push(w)
        }
        return out
    }

    PlasmaComponents.Label {
        text: profile.error ? "⚠" : (profile.displayName || profile.id || "")
        font.bold: true
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: profile.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        Layout.preferredWidth: 72
        elide: Text.ElideRight
    }

    Repeater {
        model: rowRoot.primaryWindows
        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            QuotaSlot {
                windowData: modelData
                nowMs: rowRoot.nowMs
                colorMode: index === 0 ? rowRoot.sessionColorMode : rowRoot.weeklyColorMode
            }
            PlasmaComponents.Label {
                visible: index < rowRoot.primaryWindows.length - 1
                text: "|"
                opacity: 0.4
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }
        }
    }

    Repeater {
        model: rowRoot.extraWindows
        QuotaChip {
            windowData: modelData
            nowMs: rowRoot.nowMs
            colorMode: rowRoot.weeklyColorMode
        }
    }

    PlasmaComponents.Label {
        visible: rowRoot.showBankedBadge && profile.bankedResets > 0
        text: "↻" + profile.bankedResets
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.highlightColor
        MouseArea {
            id: bankedMouse
            anchors.fill: parent
            hoverEnabled: true
        }
        QQC2.ToolTip {
            visible: bankedMouse.containsMouse
            text: profile.bankedResets + " banked reset(s)"
        }
    }

    PlasmaComponents.Label {
        visible: profile.error !== ""
        text: profile.error
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.negativeTextColor
        elide: Text.ElideRight
        Layout.fillWidth: true
    }
}