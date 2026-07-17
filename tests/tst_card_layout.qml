import QtQuick
import QtTest
import "../contents/ui"

TestCase {
    name: "CardLayout"

    Component {
        id: cardsComponent
        CardsView {
            width: 500
            height: 400
            cardMinWidth: 200
            fillWidth: true
            maxCards: 12
        }
    }

    function profile(id) {
        return {
            id: id,
            displayName: id,
            enabled: true,
            loading: false,
            error: "",
            windows: []
        }
    }

    function descendantsMatching(root, predicate) {
        var found = []
        function visit(item) {
            if (!item)
                return
            if (predicate(item))
                found.push(item)
            var children = item.children || []
            for (var i = 0; i < children.length; ++i)
                visit(children[i])
        }
        visit(root)
        return found
    }

    function accountCards(root) {
        return descendantsMatching(root, function(item) {
            return typeof item.profile !== "undefined"
                    && typeof item.minWidth !== "undefined"
        })
    }

    function labelsWithText(root, text) {
        return descendantsMatching(root, function(item) {
            return typeof item.text !== "undefined" && item.text === text
        })
    }

    function makeCards(profiles) {
        var view = createTemporaryObject(cardsComponent, null, { profiles: profiles })
        verify(view !== null, "CardsView should instantiate")
        wait(0)
        return view
    }

    function test_singleCardUsesAvailableRowWidth() {
        var view = makeCards([profile("only")])
        var cards = accountCards(view)

        compare(cards.length, 1)
        compare(cards[0].width, view.width,
                "one visible card should not reserve empty columns to its right")
    }

    function test_partialFinalRowFillsAvailableWidth() {
        var view = makeCards([profile("one"), profile("two"), profile("three")])
        var cards = accountCards(view)
        var spacing = view.children[0].spacing
        var expectedTwoColumnWidth = Math.floor((view.width - spacing) / 2)

        compare(cards.length, 3)
        compare(cards[0].width, expectedTwoColumnWidth)
        compare(cards[1].width, expectedTwoColumnWidth)
        compare(cards[2].width, view.width,
                "a lone card in the final row should not reserve an empty column")
    }

    function test_delegatesBeyondMaximumStaySafeAndInvisible() {
        var view = createTemporaryObject(
                    cardsComponent, null,
                    { profiles: [profile("one"), profile("two"), profile("three")],
                      maxCards: 2 })
        verify(view !== null, "capped CardsView should instantiate")
        wait(0)
        var cards = accountCards(view)
        var spacing = view.children[0].spacing
        var expectedTwoColumnWidth = Math.floor((view.width - spacing) / 2)

        compare(cards.length, 3)
        compare(cards[0].width, expectedTwoColumnWidth)
        compare(cards[1].width, expectedTwoColumnWidth)
        compare(cards[2].visible, false)
        compare(cards[2].width, 0)
        compare(cards[2].height, 0)

        var moreLabels = labelsWithText(view, "+1 more")
        compare(moreLabels.length, 1)
        var flow = view.children[0]
        var moreBottom = moreLabels[0].mapToItem(flow, 0, moreLabels[0].height).y
        compare(flow.implicitHeight, moreBottom,
                "Flow height should end at the visible overflow label, not a hidden card")

        var fixedWidthView = createTemporaryObject(
                    cardsComponent, null,
                    { profiles: [profile("one"), profile("two"), profile("three")],
                      maxCards: 2, fillWidth: false })
        verify(fixedWidthView !== null, "fixed-width capped CardsView should instantiate")
        wait(0)
        var fixedCards = accountCards(fixedWidthView)
        compare(fixedCards[0].width, fixedWidthView.cardMinWidth)
        compare(fixedCards[1].width, fixedWidthView.cardMinWidth)
        compare(fixedCards[2].visible, false)
        compare(fixedCards[2].width, 0)
        compare(fixedCards[2].height, 0)
    }

    function test_rightSideQuotaInformationRemainsAligned() {
        var now = 1773709200000
        var dataProfile = profile("data")
        dataProfile.lastFetchMs = now
        dataProfile.windows = [
            { id: "5h", label: "5h", usagePercent: 37,
              resetAtMs: now + 7260000, periodMs: 18000000,
              role: "primary", defaultVisible: true, visible: true },
            { id: "weekly", label: "7d", usagePercent: 81,
              resetAtMs: now + 190860000, periodMs: 604800000,
              role: "primary", defaultVisible: true, visible: true }
        ]
        var view = createTemporaryObject(cardsComponent, null,
                                         { profiles: [dataProfile], nowMs: now })
        verify(view !== null, "CardsView should instantiate with quota data")
        wait(0)

        var firstPct = labelsWithText(view, "37%")
        var secondPct = labelsWithText(view, "81%")
        var firstTime = labelsWithText(view, "2h 1m")
        var secondTime = labelsWithText(view, "2d 5h")
        compare(firstPct.length, 1)
        compare(secondPct.length, 1)
        compare(firstTime.length, 1)
        compare(secondTime.length, 1)
        // Fixed column slots: equal widths and shared left edges for % and countdown.
        compare(firstPct[0].width, secondPct[0].width)
        compare(firstTime[0].width, secondTime[0].width)
        var firstPctX = firstPct[0].mapToItem(view, 0, 0).x
        var secondPctX = secondPct[0].mapToItem(view, 0, 0).x
        var firstTimeX = firstTime[0].mapToItem(view, 0, 0).x
        var secondTimeX = secondTime[0].mapToItem(view, 0, 0).x
        verify(Math.abs(firstPctX - secondPctX) < 1,
               "percentage columns should share a left edge")
        verify(Math.abs(firstTimeX - secondTimeX) < 1,
               "countdown columns should share a left edge")
        verify(Math.abs((firstTimeX + firstTime[0].width)
                        - (secondTimeX + secondTime[0].width)) < 1,
               "countdown right edges should align within one pixel")
    }

    function test_narrowViewPreservesMinimumCardWidth() {
        var view = makeCards([profile("only")])
        view.width = 150
        wait(0)
        var cards = accountCards(view)

        compare(cards.length, 1)
        compare(cards[0].width, view.cardMinWidth)
    }
}
