import QtQuick
import QtQuick.Layouts
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
    property int maxCards: 12
    property int cardMinWidth: Kirigami.Units.gridUnit * 11
    /** When true, cards expand to fill available width in the flow. */
    property bool fillWidth: true
    property var i18n: null

    signal detailRequested(var profile)

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
                profile: modelData
                nowMs: cardsRoot.nowMs
                sessionColorMode: cardsRoot.sessionColorMode
                weeklyColorMode: cardsRoot.weeklyColorMode
                showBankedBadge: cardsRoot.showBankedBadge
                minWidth: cardsRoot.cardMinWidth
                width: {
                    if (!cardsRoot.fillWidth)
                        return minWidth
                    var avail = cardFlow.width > 0 ? cardFlow.width : cardsRoot.width
                    if (avail <= 0)
                        return minWidth
                    var cols = Math.max(1, Math.floor((avail + cardFlow.spacing)
                                        / (minWidth + cardFlow.spacing)))
                    var n = Math.min(cardsRoot.cards.length, cardsRoot.maxCards)
                    if (n <= 0)
                        return minWidth
                    // Prefer filling: use actual column count for current width
                    var w = Math.floor((avail - cardFlow.spacing * (cols - 1)) / cols)
                    return Math.max(minWidth, w)
                }
                onDetailRequested: function(p) { cardsRoot.detailRequested(p) }
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
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }

        PlasmaComponents.Label {
            visible: cardsRoot.cards.length === 0 && !cardsRoot.isLoading
            text: cardsRoot.tr("No profiles")
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }
        // Loading count lives in the host chrome (header), not as a stray Flow item.
    }
}
