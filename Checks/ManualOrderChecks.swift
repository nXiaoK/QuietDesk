import Foundation
import QuietDeskCore

func runManualOrderChecks() {
    run("A hand-arranged order keeps its entries in place, puts new ones first and forgets removed ones") {
        let newestFirst = ["c", "a", "b"]
        try check(ManualOrder.arranged(newestFirst, by: []) == newestFirst, "Without an order the entries did not stay as they come")
        try check(ManualOrder.arranged(newestFirst, by: ["a", "b", "c"]) == ["a", "b", "c"], "The arranged order was not kept")
        // Connecting to an entry makes it the newest; the arrangement does not change.
        try check(ManualOrder.arranged(["b", "c", "a"], by: ["a", "b", "c"]) == ["a", "b", "c"], "A newer connection reordered the list")
        // An entry added later is not named yet: it comes first, newest first among such entries.
        try check(ManualOrder.arranged(["e", "c", "d", "a", "b"], by: ["a", "b", "c"]) == ["e", "d", "a", "b", "c"],
                  "New entries were not put first as they come")
        // Names of removed entries and names given twice are ignored.
        try check(ManualOrder.arranged(["a", "b"], by: ["x", "b", "b", "a", "y"]) == ["b", "a"], "A removed or repeated name disturbed the order")
        try check(ManualOrder.arranged([String](), by: ["a"]).isEmpty, "An empty list did not stay empty")
    }

    run("Moving entries reports the whole new order, for any offsets and destination a drag can report") {
        let list = ["a", "b", "c", "d"]
        // SwiftUI's destination counts positions before the move: 0 is before the first entry, 4 after the last.
        try check(ManualOrder.moving(list, from: IndexSet(integer: 0), to: 3) == ["b", "c", "a", "d"], "Moving down landed in the wrong place")
        try check(ManualOrder.moving(list, from: IndexSet(integer: 3), to: 0) == ["d", "a", "b", "c"], "Moving up landed in the wrong place")
        try check(ManualOrder.moving(list, from: IndexSet(integer: 0), to: 4) == ["b", "c", "d", "a"], "Moving to the end landed in the wrong place")
        // Dropping an entry on either side of itself changes nothing.
        try check(ManualOrder.moving(list, from: IndexSet(integer: 1), to: 1) == list && ManualOrder.moving(list, from: IndexSet(integer: 1), to: 2) == list,
                  "Dropping an entry where it was moved it")
        try check(ManualOrder.moving(list, from: IndexSet([0, 2]), to: 4) == ["b", "d", "a", "c"], "Several entries did not move together in order")
        try check(ManualOrder.moving(list, from: IndexSet([1, 3]), to: 0) == ["b", "d", "a", "c"], "Several entries did not move to the front in order")
        // Offsets outside the list and destinations beyond its ends cannot lose or repeat an entry.
        for (offsets, destination) in [(IndexSet(integer: 9), 0), (IndexSet([0, 9]), 99), (IndexSet(integer: 2), -5), (IndexSet(), 2)] {
            let moved = ManualOrder.moving(list, from: offsets, to: destination)
            try check(moved.sorted() == list, "A move lost or repeated an entry: \(moved)")
        }
        try check(ManualOrder.moving(list, from: IndexSet([0, 9]), to: 99) == ["b", "c", "d", "a"], "An offset outside the list changed where the others went")
        // What a drag saves arranges the same entries the same way afterwards.
        let saved = ManualOrder.moving(ManualOrder.arranged(["e", "a", "b"], by: ["b", "a"]), from: IndexSet(integer: 0), to: 3)
        try check(saved == ["b", "a", "e"] && ManualOrder.arranged(["a", "e", "b"], by: saved) == saved, "A saved move did not read back: \(saved)")
    }
}
