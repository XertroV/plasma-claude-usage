import QtQuick
import QtTest
import "../contents/ui"

TestCase {
    name: "QuotaPresentation"

    Component {
        id: cardComponent
        AccountCard {
            width: 500
            nowMs: 1773709200000
        }
    }

    Component {
        id: detailComponent
        DetailWindow {
            visible: false
            nowMs: 1773709200000
        }
    }

    function profileWithExtra() {
        return {
            id: "claude",
            displayName: "Claude",
            enabled: true,
            loading: false,
            error: "",
            lastFetchMs: 1773709200000,
            windows: [
                { id: "5h", label: "5h", usagePercent: 37,
                  resetAtMs: 1773716460000, periodMs: 18000000,
                  role: "primary", visible: true },
                { id: "weekly_fable", label: "Fable", usagePercent: 42,
                  resetAtMs: 1773899200000, periodMs: 604800000,
                  role: "extra", visible: true }
            ]
        }
    }

    function descendantsMatching(root, predicate, seen) {
        var visited = seen || []
        if (!root || visited.indexOf(root) >= 0)
            return []
        visited.push(root)
        var found = predicate(root) ? [root] : []
        var children = root.children || []
        for (var i = 0; i < children.length; i++)
            found = found.concat(descendantsMatching(children[i], predicate, visited))
        if (root.contentItem)
            found = found.concat(descendantsMatching(root.contentItem, predicate, visited))
        return found
    }

    function labelsWithText(root, text) {
        return descendantsMatching(root, function(item) {
            return typeof item.text !== "undefined" && item.text === text
        })
    }

    function test_cardTreatsSelectedExtraAsNormalRow() {
        var card = createTemporaryObject(cardComponent, null,
                                         { profile: profileWithExtra() })
        verify(card !== null)
        wait(0)
        verify(typeof card.quotaPresentation !== "undefined",
               "card exposes the shared presentation snapshot")
        compare(card.quotaPresentation.rows.length, 2)
        compare(labelsWithText(card, "5h").length, 1)
        compare(labelsWithText(card, "Fable").length, 1)
        compare(labelsWithText(card, "37%").length, 1)
        compare(labelsWithText(card, "42%").length, 1)
    }

    function test_detailUsesOneEqualQuotaList() {
        var profile = profileWithExtra()
        var detail = createTemporaryObject(detailComponent, null,
                                           { profile: profile, profiles: [profile] })
        verify(detail !== null)
        wait(0)
        compare(labelsWithText(detail, "Quotas").length, 1)
        compare(labelsWithText(detail, "Primary").length, 0)
        compare(labelsWithText(detail, "Extra limits").length, 0)
        compare(labelsWithText(detail, "5h").length, 1)
        compare(labelsWithText(detail, "Fable").length, 1)
        compare(labelsWithText(detail, "37%").length, 1)
        compare(labelsWithText(detail, "42%").length, 1)
    }
}
