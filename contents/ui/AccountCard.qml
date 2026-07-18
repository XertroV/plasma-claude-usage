import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaPresentation.js" as QP

// One profile/account card for the panel flow layout.
Rectangle {
    id: cardRoot

    property var profile: null
    property double nowMs: Date.now()
    /** Bumped with controller dataEpoch so nested windows re-present after fetch. */
    property int dataEpoch: 0
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true
    property int minWidth: Kirigami.Units.gridUnit * 11
    /** When celebrateGeneration bumps and celebrateProfileId matches, party. */
    property string celebrateProfileId: ""
    property int celebrateGeneration: 0

    readonly property int contentFontPixelSize: Math.round(
        (Kirigami.Theme.smallFont.pixelSize + Kirigami.Theme.defaultFont.pixelSize) / 2)

    signal detailRequested(var profile)
    signal refreshRequested(var profile)

    // Explicit deps: QML does not deep-track profile.windows for .pragma library calls.
    readonly property var quotaPresentation: {
        var _epoch = dataEpoch
        var p = profile
        var _winLen = p && p.windows ? p.windows.length : 0
        var _last = p ? p.lastFetchMs : 0
        var _loading = p ? p.loading : false
        return QP.presentProfile(p, {
            sessionColorMode: sessionColorMode,
            weeklyColorMode: weeklyColorMode
        })
    }
    readonly property var quotaRows: {
        var presentation = quotaPresentation
        return presentation && presentation.rows ? presentation.rows : []
    }
    // Any in-flight fetch (refresh or first load)
    readonly property bool refreshing: !!(profile && profile.loading)
    // First load only — no windows yet. Never collapse existing rows while refreshing.
    readonly property bool initialLoad: refreshing
            && !(profile && profile.windows && profile.windows.length)
    readonly property bool hasError: !!(profile && profile.error)
    readonly property string title: profile
            ? (profile.displayName || profile.id || "?") : "…"

    // Idle chrome (overridden during celebration)
    readonly property color idleFill: Qt.rgba(Kirigami.Theme.textColor.r,
            Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06)
    readonly property color idleBorder: Qt.rgba(Kirigami.Theme.textColor.r,
            Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
    readonly property color partyBorder: Kirigami.Theme.positiveTextColor
            || Kirigami.Theme.highlightColor
    readonly property color partyFill: Qt.rgba(partyBorder.r, partyBorder.g,
            partyBorder.b, 0.18)

    property bool celebrating: false
    property real partyGlow: 0
    property real partyEmojiOpacity: 0
    property real partyEmojiScale: 0.4
    property color fillColor: idleFill
    property color borderColor: idleBorder
    property int borderPx: 1

    implicitWidth: Math.max(minWidth, contentCol.implicitWidth + Kirigami.Units.smallSpacing * 2)
    implicitHeight: contentCol.implicitHeight + Kirigami.Units.smallSpacing * 2
    width: implicitWidth
    height: implicitHeight

    radius: Kirigami.Units.smallSpacing
    color: fillColor
    border.color: borderColor
    border.width: borderPx
    // Allow shake/bounce to paint slightly outside bounds during the party.
    clip: !celebrating

    transform: [
        Translate { id: shakeX; x: 0 },
        Scale {
            id: bounceScale
            origin.x: cardRoot.width / 2
            origin.y: cardRoot.height / 2
            xScale: 1
            yScale: 1
        }
    ]

    onCelebrateGenerationChanged: {
        if (celebrateGeneration <= 0)
            return
        if (!profile || !profile.id)
            return
        if (String(profile.id) !== String(celebrateProfileId))
            return
        playCelebration()
    }

    function restoreIdleChrome() {
        // ColorAnimation / assignment break property bindings — rebind so theme
        // switches still update fill/border after a party.
        fillColor = Qt.binding(function() { return idleFill })
        borderColor = Qt.binding(function() { return idleBorder })
        borderPx = 1
        celebrating = false
        shakeX.x = 0
        bounceScale.xScale = 1
        bounceScale.yScale = 1
        partyGlow = 0
        partyEmojiOpacity = 0
        partyEmojiScale = 0.4
    }

    function playCelebration() {
        if (celebrateAnim.running)
            celebrateAnim.stop()
        restoreIdleChrome()
        celebrating = true
        celebrateAnim.start()
    }

    SequentialAnimation {
        id: celebrateAnim
        // Pop in: glow + bounce
        ParallelAnimation {
            NumberAnimation {
                target: cardRoot; property: "partyGlow"
                from: 0; to: 1; duration: 140
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: cardRoot; property: "borderPx"
                from: 1; to: 2; duration: 140
            }
            ColorAnimation {
                target: cardRoot; property: "borderColor"
                to: cardRoot.partyBorder; duration: 140
            }
            ColorAnimation {
                target: cardRoot; property: "fillColor"
                to: cardRoot.partyFill; duration: 140
            }
            NumberAnimation {
                target: bounceScale; property: "xScale"
                from: 1; to: 1.055; duration: 160
                easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: bounceScale; property: "yScale"
                from: 1; to: 1.055; duration: 160
                easing.type: Easing.OutBack
            }
            NumberAnimation {
                target: cardRoot; property: "partyEmojiOpacity"
                from: 0; to: 1; duration: 120
            }
            NumberAnimation {
                target: cardRoot; property: "partyEmojiScale"
                from: 0.35; to: 1.15; duration: 220
                easing.type: Easing.OutBack
            }
        }
        // Happy shake
        SequentialAnimation {
            NumberAnimation { target: shakeX; property: "x"; to: 5; duration: 35 }
            NumberAnimation { target: shakeX; property: "x"; to: -5; duration: 40 }
            NumberAnimation { target: shakeX; property: "x"; to: 4; duration: 35 }
            NumberAnimation { target: shakeX; property: "x"; to: -3; duration: 35 }
            NumberAnimation { target: shakeX; property: "x"; to: 2; duration: 30 }
            NumberAnimation { target: shakeX; property: "x"; to: 0; duration: 30
                easing.type: Easing.OutCubic }
        }
        // Settle: scale home, fade glow, float emoji away
        ParallelAnimation {
            NumberAnimation {
                target: bounceScale; property: "xScale"
                to: 1; duration: 280
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: bounceScale; property: "yScale"
                to: 1; duration: 280
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: cardRoot; property: "partyGlow"
                to: 0; duration: 520
                easing.type: Easing.InOutQuad
            }
            NumberAnimation {
                target: cardRoot; property: "borderPx"
                to: 1; duration: 400
            }
            ColorAnimation {
                target: cardRoot; property: "borderColor"
                to: cardRoot.idleBorder; duration: 450
            }
            ColorAnimation {
                target: cardRoot; property: "fillColor"
                to: cardRoot.idleFill; duration: 450
            }
            NumberAnimation {
                target: cardRoot; property: "partyEmojiOpacity"
                to: 0; duration: 420
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: cardRoot; property: "partyEmojiScale"
                to: 1.45; duration: 420
                easing.type: Easing.InQuad
            }
        }
        ScriptAction {
            script: cardRoot.restoreIdleChrome()
        }
    }

    // Soft highlight wash over the card face during celebration
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        z: 1
        color: cardRoot.partyBorder
        opacity: cardRoot.partyGlow * 0.22
        visible: opacity > 0.01
        // Let clicks pass through to controls underneath
        enabled: false
    }

    // Party emoji that pops then floats off
    Text {
        anchors.centerIn: parent
        z: 2
        text: "🎉"
        font.pixelSize: Math.max(18, Math.round(cardRoot.height * 0.42))
        opacity: cardRoot.partyEmojiOpacity
        scale: cardRoot.partyEmojiScale
        visible: opacity > 0.01
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.25)
        enabled: false
    }

    ColumnLayout {
        id: contentCol
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)
        z: 0

        // Header: name · inline error · banked · refresh/spinner · detail
        RowLayout {
            id: headerRow
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            // This slot absorbs width pressure before the always-allocated controls do.
            Item {
                id: headerTextSlot
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: Math.max(nameLabel.implicitHeight, errorLabel.implicitHeight)

                PlasmaComponents.Label {
                    id: nameLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(
                        implicitWidth,
                        headerTextSlot.width * (cardRoot.hasError ? 0.4 : 1))
                    text: cardRoot.title
                    font.bold: true
                    font.pixelSize: cardRoot.contentFontPixelSize
                    color: Kirigami.Theme.textColor
                    elide: Text.ElideRight

                    HoverHandler { id: nameHover }
                    QQC2.ToolTip {
                        visible: nameHover.hovered
                        text: {
                            var bits = [cardRoot.title]
                            if (profile && profile.planName) bits.push(profile.planName)
                            if (profile && profile.configDir) bits.push(profile.configDir)
                            if (cardRoot.refreshing) bits.push("Refreshing…")
                            return bits.join("\n")
                        }
                    }
                }

                PlasmaComponents.Label {
                    id: errorLabel
                    anchors.left: nameLabel.right
                    anchors.leftMargin: visible ? Kirigami.Units.smallSpacing : 0
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: cardRoot.hasError
                    text: cardRoot.hasError ? ("⚠ " + cardRoot.profile.error) : ""
                    textFormat: Text.PlainText
                    font.pixelSize: cardRoot.contentFontPixelSize
                    color: Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    Accessible.name: cardRoot.hasError
                        ? ("Error: " + cardRoot.profile.error) : ""
                    Accessible.role: Accessible.StaticText
                    Accessible.ignored: !cardRoot.hasError

                    HoverHandler { id: errorHover }
                    QQC2.ToolTip {
                        visible: errorHover.hovered && cardRoot.hasError
                        text: cardRoot.hasError ? cardRoot.profile.error : ""
                    }
                }
            }

            PlasmaComponents.Label {
                visible: showBankedBadge && profile && profile.bankedResets > 0
                text: "↻" + profile.bankedResets
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.highlightColor
                HoverHandler { id: bankedHover }
                QQC2.ToolTip {
                    visible: bankedHover.hovered
                    text: profile.bankedResets + " banked reset(s)"
                }
            }

            // Always-allocated slot: refresh control idle, spinner while this profile loads
            Item {
                id: refreshSlot
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.alignment: Qt.AlignVCenter

                PlasmaComponents.BusyIndicator {
                    anchors.fill: parent
                    visible: cardRoot.refreshing
                    running: cardRoot.refreshing
                    Accessible.name: "Refreshing"
                    Accessible.ignored: !cardRoot.refreshing
                }

                Kirigami.Icon {
                    anchors.fill: parent
                    source: "view-refresh"
                    opacity: refreshMouse.containsMouse ? 1 : 0.55
                    visible: !cardRoot.refreshing
                    color: Kirigami.Theme.textColor
                    Accessible.name: "Refresh"
                    Accessible.role: Accessible.Button
                    Accessible.ignored: cardRoot.refreshing
                }

                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    anchors.margins: -Kirigami.Units.smallSpacing / 2
                    enabled: !cardRoot.refreshing && !!cardRoot.profile
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (cardRoot.profile)
                            cardRoot.refreshRequested(cardRoot.profile)
                    }
                }
                QQC2.ToolTip {
                    visible: refreshMouse.containsMouse && !cardRoot.refreshing
                    text: "Refresh"
                }
            }

            // B022: never put MouseArea as a bare RowLayout child (zero size).
            // Wrap the "⋯" control in an Item with real implicit size for hit testing.
            Item {
                id: detailBtn
                implicitWidth: Math.max(Kirigami.Units.iconSizes.small,
                                        detailDots.implicitWidth + Kirigami.Units.smallSpacing * 2)
                implicitHeight: Math.max(Kirigami.Units.iconSizes.small,
                                         detailDots.implicitHeight + Kirigami.Units.smallSpacing * 2)
                Layout.preferredWidth: implicitWidth
                Layout.preferredHeight: implicitHeight
                Layout.alignment: Qt.AlignVCenter
                Accessible.name: "Details"
                Accessible.role: Accessible.Button
                Accessible.onPressAction: cardRoot.detailRequested(cardRoot.profile)

                PlasmaComponents.Label {
                    id: detailDots
                    anchors.centerIn: parent
                    text: "⋯"
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: detailHover.hovered
                           ? Kirigami.Theme.textColor
                           : Kirigami.Theme.disabledTextColor
                }

                HoverHandler { id: detailHover }
                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: cardRoot.detailRequested(cardRoot.profile)
                }
                QQC2.ToolTip {
                    visible: detailHover.hovered
                    text: "Details"
                }
            }
        }

        // Selected quota rows or first-load skeleton (stale rows kept while refreshing)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Math.max(2, Kirigami.Units.smallSpacing / 2)
            visible: !hasError || (quotaRows && quotaRows.length)

            // Index model (not a JS object array): more reliable under Flow/Repeater
            // than modelData-from-array, which can lose nested windowData in some Qt builds.
            Repeater {
                model: {
                    var rows = cardRoot.quotaRows
                    if (rows && rows.length > 0)
                        return rows.length
                    // First load / empty: two skeleton rows (not on mid-refresh with data)
                    if (cardRoot.initialLoad || (profile && !profile.lastFetchMs && !hasError))
                        return 2
                    return 0
                }
                QuotaRow {
                    required property int index
                    Layout.fillWidth: true
                    presentationRow: {
                        var rows = cardRoot.quotaRows
                        return (rows && index < rows.length) ? rows[index] : null
                    }
                    nowMs: cardRoot.nowMs
                    mode: {
                        var rows = cardRoot.quotaRows
                        return (rows && index < rows.length && rows[index]) ? "data" : "skeleton"
                    }
                    compact: true
                    textPixelSize: cardRoot.contentFontPixelSize
                    // Slight dim while refreshing existing data
                    opacity: {
                        var rows = cardRoot.quotaRows
                        return (rows && index < rows.length && cardRoot.refreshing) ? 0.75 : 1
                    }
                }
            }
        }
    }
}
