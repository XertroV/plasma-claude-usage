import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Shared list/flow of account cards — used by panel (compact) and main window (full).
Item {
    id: cardsRoot

    property var profiles: []
    property int dataEpoch: 0
    property double nowMs: Date.now()
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property bool showBankedBadge: true
    property bool isLoading: false
    property string loadingText: ""
    // Discovery failure from ProfileController (B017); shown in empty state
    property string discoveryError: ""
    property int maxCards: 12
    property int cardMinWidth: Kirigami.Units.gridUnit * 11
    readonly property int contentFontPixelSize: Math.round(
        (Kirigami.Theme.smallFont.pixelSize + Kirigami.Theme.defaultFont.pixelSize) / 2)
    /** When true, cards expand to fill available width in the flow. */
    property bool fillWidth: true
    property var i18n: null
    // Quota-reset card celebration (from ProfileController)
    property string celebrateProfileId: ""
    property int celebrateGeneration: 0
    property bool reducedMotion: Kirigami.Units.longDuration <= 0

    signal detailRequested(var profile)
    signal refreshRequested(var profile)

    function tr(t) { return i18n ? i18n.tr(t) : t }

    function enabledList() {
        var out = []
        var list = profiles || []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].enabled !== false)
                out.push(list[i])
        }
        return out
    }

    readonly property var cards: {
        var _ = dataEpoch
        return enabledList()
    }

    implicitWidth: Math.max(cardMinWidth, cardFlow.implicitWidth)
    implicitHeight: Math.max(Kirigami.Units.gridUnit * 4, cardFlow.implicitHeight)

    Flow {
        id: cardFlow
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing
        flow: Flow.LeftToRight

        Repeater {
            model: {
                var _ = cardsRoot.dataEpoch
                return cardsRoot.cards
            }
            AccountCard {
                required property var modelData
                required property int index
                visible: index < cardsRoot.maxCards
                height: visible ? implicitHeight : 0
                profile: modelData
                dataEpoch: cardsRoot.dataEpoch
                nowMs: cardsRoot.nowMs
                sessionColorMode: cardsRoot.sessionColorMode
                weeklyColorMode: cardsRoot.weeklyColorMode
                showBankedBadge: cardsRoot.showBankedBadge
                celebrateProfileId: cardsRoot.celebrateProfileId
                celebrateGeneration: cardsRoot.celebrateGeneration
                reducedMotion: cardsRoot.reducedMotion
                minWidth: cardsRoot.cardMinWidth
                width: {
                    var n = Math.min(cardsRoot.cards.length, cardsRoot.maxCards)
                    if (n <= 0 || index >= n)
                        return 0
                    if (!cardsRoot.fillWidth)
                        return minWidth
                    var avail = cardFlow.width > 0 ? cardFlow.width : cardsRoot.width
                    if (avail <= 0)
                        return minWidth
                    var capacity = Math.max(1, Math.floor((avail + cardFlow.spacing)
                                            / (minWidth + cardFlow.spacing)))
                    // Fill each row without reserving columns for cards that are not in it.
                    var rowStart = Math.floor(index / capacity) * capacity
                    var cols = Math.min(capacity, n - rowStart)
                    var w = Math.floor((avail - cardFlow.spacing * (cols - 1)) / cols)
                    return Math.max(minWidth, w)
                }
                onDetailRequested: function(p) { cardsRoot.detailRequested(p) }
                onRefreshRequested: function(p) { cardsRoot.refreshRequested(p) }
            }
        }

        // Skeleton cards when discovering
        Repeater {
            model: (cardsRoot.cards.length === 0 && cardsRoot.isLoading) ? 2 : 0
            AccountCard {
                profile: ({ displayName: "…", loading: true, windows: [], error: "" })
                nowMs: cardsRoot.nowMs
                minWidth: cardsRoot.cardMinWidth
                width: {
                    var avail = cardFlow.width > 0 ? cardFlow.width : cardsRoot.width
                    if (avail <= 0) return minWidth
                    return Math.max(minWidth, Math.floor((avail - cardFlow.spacing) / 2))
                }
            }
        }

        PlasmaComponents.Label {
            visible: cardsRoot.cards.length > cardsRoot.maxCards
            text: "+" + (cardsRoot.cards.length - cardsRoot.maxCards) + " more"
            font.pixelSize: cardsRoot.contentFontPixelSize
            color: Kirigami.Theme.disabledTextColor
        }

        // B022: hover/click on a sized Item, not a bare layout MouseArea.
        // B017: surface discoveryError in empty state (and still allow unhide click).
        Item {
            id: emptyState
            visible: cardsRoot.cards.length === 0 && !cardsRoot.isLoading
            implicitWidth: Math.max(
                emptyLabel.implicitWidth + Kirigami.Units.smallSpacing * 2,
                Math.min(cardsRoot.cardMinWidth,
                         cardFlow.width > 0 ? cardFlow.width : cardsRoot.width))
            implicitHeight: emptyLabel.implicitHeight + Kirigami.Units.smallSpacing * 2
            width: implicitWidth
            height: implicitHeight
            Accessible.name: emptyLabel.text
            Accessible.role: Accessible.Button
            Accessible.onPressAction: emptyState.openFirstDetail()

            readonly property bool canUnhide: (cardsRoot.profiles || []).length > 0
            readonly property bool hasDiscoveryError:
                cardsRoot.discoveryError && cardsRoot.discoveryError !== ""

            function openFirstDetail() {
                if (!canUnhide)
                    return
                var list = cardsRoot.profiles || []
                for (var i = 0; i < list.length; i++) {
                    if (list[i] && list[i].id) {
                        cardsRoot.detailRequested(list[i])
                        return
                    }
                }
            }

            PlasmaComponents.Label {
                id: emptyLabel
                anchors.centerIn: parent
                width: Math.max(1, emptyState.width - Kirigami.Units.smallSpacing * 2)
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                text: {
                    if (emptyState.hasDiscoveryError)
                        return cardsRoot.discoveryError
                    if (emptyState.canUnhide)
                        return cardsRoot.tr("All accounts hidden")
                    return cardsRoot.tr("No profiles")
                }
                font.pixelSize: cardsRoot.contentFontPixelSize
                color: emptyState.hasDiscoveryError
                       ? Kirigami.Theme.negativeTextColor
                       : Kirigami.Theme.disabledTextColor
            }

            HoverHandler {
                id: emptyHover
                enabled: emptyState.canUnhide || emptyState.hasDiscoveryError
            }
            TapHandler {
                enabled: emptyState.canUnhide
                cursorShape: emptyState.canUnhide ? Qt.PointingHandCursor : Qt.ArrowCursor
                onTapped: emptyState.openFirstDetail()
            }
            QQC2.ToolTip {
                visible: emptyHover.hovered && (emptyState.canUnhide || emptyState.hasDiscoveryError)
                text: {
                    var parts = []
                    if (emptyState.hasDiscoveryError)
                        parts.push(cardsRoot.discoveryError)
                    if (emptyState.canUnhide)
                        parts.push(cardsRoot.tr("Open details to unhide"))
                    return parts.join("\n")
                }
            }
        }
        // Loading count lives in host chrome, not as a stray Flow item.
    }
}
