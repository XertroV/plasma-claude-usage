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
        var view = makeCards([profile("one"), profile("two"), profile("three")])
        view.maxCards = 2
        wait(0)
        var cards = accountCards(view)
        var spacing = view.children[0].spacing
        var expectedTwoColumnWidth = Math.floor((view.width - spacing) / 2)

        compare(cards.length, 3)
        compare(cards[0].width, expectedTwoColumnWidth)
        compare(cards[1].width, expectedTwoColumnWidth)
        compare(cards[2].visible, false)
        compare(cards[2].width, view.cardMinWidth)
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
        compare(firstPct[0].mapToItem(view, 0, 0).x,
                secondPct[0].mapToItem(view, 0, 0).x)
        compare(firstTime[0].mapToItem(view, 0, 0).x,
                secondTime[0].mapToItem(view, 0, 0).x)
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
