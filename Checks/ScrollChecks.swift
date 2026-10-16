import QuietDeskCore

func runScrollChecks() {
    run("Fine scrolling accumulates positive and negative subpixel movement") {
        for direction: Double in [-1, 1] {
            var scroll = ScrollAccumulator()
            var pixels: Int32 = 0
            for _ in 0..<100 {
                if let step = try scroll.accumulate(deltaX: 0, deltaY: direction * 0.2) {
                    try check(step.x == 0, "Vertical scrolling changed the horizontal axis")
                    pixels += step.y
                }
            }
            try check(pixels == Int32(direction * 20), "Fine scrolling was lost or changed direction")
        }
    }

    run("Scroll axes accumulate independently and preserve ordinary wheel deltas") {
        var scroll = ScrollAccumulator()
        try check(try scroll.accumulate(deltaX: 0.25, deltaY: -0.5) == nil, "Subpixel motion produced an empty event")
        let vertical = try scroll.accumulate(deltaX: 0.25, deltaY: -0.5)
        try check(vertical?.x == 0 && vertical?.y == -1, "Vertical accumulation affected horizontal remainder")
        let horizontal = try scroll.accumulate(deltaX: 0.5, deltaY: 0)
        try check(horizontal?.x == 1 && horizontal?.y == 0, "Horizontal remainder was lost")
        let wheel = try scroll.accumulate(deltaX: -24, deltaY: 36)
        try check(wheel?.x == -24 && wheel?.y == 36, "Ordinary mouse wheel amount or direction changed")
    }

    run("Reversing and releasing control do not leave delayed scroll movement") {
        var scroll = ScrollAccumulator()
        try check(try scroll.accumulate(deltaX: 0.75, deltaY: -0.75) == nil, "Partial scroll emitted pixels")
        try check(try scroll.accumulate(deltaX: -0.75, deltaY: 0.75) == nil, "Reversed motion did not cancel")
        try check(try scroll.accumulate(deltaX: 0, deltaY: 0) == nil, "Cancelled motion left a scroll event")
        _ = try scroll.accumulate(deltaX: -0.75, deltaY: 0.75)
        scroll.reset()
        try check(try scroll.accumulate(deltaX: -0.5, deltaY: 0.5) == nil, "Released control retained old movement")
        let pixels = try scroll.accumulate(deltaX: -0.5, deltaY: 0.5)
        try check(pixels?.x == -1 && pixels?.y == 1, "Fresh movement after reset was lost")
    }

    run("Scroll limits reject invalid values without changing pending movement") {
        var scroll = ScrollAccumulator()
        _ = try scroll.accumulate(deltaX: 0.5, deltaY: -0.5)
        for invalid in [Double.nan, .infinity, -.infinity, 3000.1, -3000.1, .greatestFiniteMagnitude] {
            try rejects("Accepted invalid horizontal scroll") { _ = try scroll.accumulate(deltaX: invalid, deltaY: 0.5) }
            try rejects("Accepted invalid vertical scroll") { _ = try scroll.accumulate(deltaX: 0.5, deltaY: invalid) }
        }
        let pending = try scroll.accumulate(deltaX: 0.5, deltaY: -0.5)
        try check(pending?.x == 1 && pending?.y == -1, "Rejected input altered pending movement")
        let limit = try scroll.accumulate(deltaX: 3000, deltaY: -3000)
        try check(limit?.x == 3000 && limit?.y == -3000, "Valid limits overflowed or were truncated")
    }
}
