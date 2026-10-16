public struct ScrollAccumulator: Sendable {
    private var remainderX: Double = 0
    private var remainderY: Double = 0

    public init() {}

    public mutating func accumulate(deltaX: Double, deltaY: Double) throws -> (x: Int32, y: Int32)? {
        guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 3000, abs(deltaY) <= 3000 else {
            throw DeskError.invalid("远端滚动参数无效")
        }
        let totalX = remainderX + deltaX
        let totalY = remainderY + deltaY
        let pixelsX = totalX.rounded(.towardZero)
        let pixelsY = totalY.rounded(.towardZero)
        remainderX = totalX - pixelsX
        remainderY = totalY - pixelsY
        guard pixelsX != 0 || pixelsY != 0 else { return nil }
        return (Int32(pixelsX), Int32(pixelsY))
    }

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }
}
