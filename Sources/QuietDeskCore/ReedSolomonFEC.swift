import Foundation

/// Systematic Cauchy Reed-Solomon erasure coding over GF(2^8) (primitive polynomial x^8 + x^4 + x^3 + x^2 + 1, 0x11D).
/// Every square submatrix of the Cauchy encoding matrix is guaranteed non-singular (MDS), enabling 0-RTT recovery of
/// any subset of up to `parityCount` lost fragments within a block.
public enum ReedSolomonGF256 {
    public static let maximumDataShards = 16
    public static let maximumParityShards = 4

    private static let tables: (inv: [UInt8], mul: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var value = 1
        for power in 0..<255 {
            exp[power] = UInt8(value)
            exp[power + 255] = UInt8(value)
            log[value] = power
            value <<= 1
            if (value & 0x100) != 0 {
                value ^= 0x11D
            }
        }
        exp[510] = exp[0]
        exp[511] = exp[1]

        var inv = [UInt8](repeating: 0, count: 256)
        inv[1] = 1
        for a in 2..<256 {
            inv[a] = exp[255 - log[a]]
        }

        var mul = [UInt8](repeating: 0, count: 256 * 256)
        for a in 1..<256 {
            let logA = log[a]
            let rowOffset = a << 8
            for b in 1..<256 {
                mul[rowOffset | b] = exp[logA + log[b]]
            }
        }
        return (inv, mul)
    }()

    @inline(__always)
    public static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        tables.mul[(Int(a) << 8) | Int(b)]
    }

    @inline(__always)
    public static func inverse(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "GF(256) zero has no multiplicative inverse")
        return tables.inv[Int(a)]
    }

    /// Cauchy matrix element C[r, c] = 1 / (x_r ^ y_c), with disjoint x_r in 0..<4 and y_c in 16..<32.
    @inline(__always)
    public static func cauchyCoefficient(parityRow: Int, dataColumn: Int) -> UInt8 {
        precondition((0..<maximumParityShards).contains(parityRow) && (0..<maximumDataShards).contains(dataColumn))
        let x = UInt8(parityRow)
        let y = UInt8(16 + dataColumn)
        return tables.inv[Int(x ^ y)]
    }

    private static func mulAdd(into destination: inout [UInt8], source: Data, coefficient: UInt8) {
        guard coefficient != 0, !source.isEmpty else { return }
        let count = min(destination.count, source.count)
        if coefficient == 1 {
            source.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<count {
                    destination[index] ^= src[index]
                }
            }
            return
        }
        let rowBase = Int(coefficient) << 8
        let mul = tables.mul
        mul.withUnsafeBufferPointer { mulPtr in
            guard let row = mulPtr.baseAddress?.advanced(by: rowBase) else { return }
            source.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<count {
                    destination[index] ^= row[Int(src[index])]
                }
            }
        }
    }

    private static func mulAdd(into destination: inout [UInt8], source: [UInt8], coefficient: UInt8) {
        guard coefficient != 0, !source.isEmpty else { return }
        let count = min(destination.count, source.count)
        if coefficient == 1 {
            for index in 0..<count {
                destination[index] ^= source[index]
            }
            return
        }
        let rowBase = Int(coefficient) << 8
        let mul = tables.mul
        mul.withUnsafeBufferPointer { mulPtr in
            guard let row = mulPtr.baseAddress?.advanced(by: rowBase) else { return }
            for index in 0..<count {
                destination[index] ^= row[Int(source[index])]
            }
        }
    }

    /// Inverts an `n x n` matrix over GF(2^8) using Gauss-Jordan elimination with partial pivoting.
    public static func invertMatrix(_ matrix: [UInt8], size n: Int) throws -> [UInt8] {
        guard n > 0, matrix.count == n * n else {
            throw DeskError.invalid("纠错矩阵维度无效")
        }
        var work = matrix
        var inverseOut = [UInt8](repeating: 0, count: n * n)
        for index in 0..<n {
            inverseOut[index * n + index] = 1
        }

        for col in 0..<n {
            var pivotRow = col
            while pivotRow < n && work[pivotRow * n + col] == 0 {
                pivotRow += 1
            }
            guard pivotRow < n else {
                throw DeskError.invalid("纠错子矩阵不可逆")
            }
            if pivotRow != col {
                for k in 0..<n {
                    work.swapAt(col * n + k, pivotRow * n + k)
                    inverseOut.swapAt(col * n + k, pivotRow * n + k)
                }
            }
            let pivotVal = work[col * n + col]
            if pivotVal != 1 {
                let invPivot = inverse(pivotVal)
                for k in 0..<n {
                    work[col * n + k] = multiply(work[col * n + k], invPivot)
                    inverseOut[col * n + k] = multiply(inverseOut[col * n + k], invPivot)
                }
            }
            for row in 0..<n where row != col {
                let factor = work[row * n + col]
                guard factor != 0 else { continue }
                for k in 0..<n {
                    work[row * n + k] ^= multiply(factor, work[col * n + k])
                    inverseOut[row * n + k] ^= multiply(factor, inverseOut[col * n + k])
                }
            }
        }
        return inverseOut
    }

    public static func encodeParityShards(
        dataShards: [Data],
        shardLength: Int,
        parityCount: Int
    ) throws -> [Data] {
        guard (2...maximumDataShards).contains(dataShards.count),
              (1...maximumParityShards).contains(parityCount),
              shardLength > 0,
              dataShards.allSatisfy({ $0.count <= shardLength }) else {
            throw DeskError.invalid("分块纠错编码参数超出范围")
        }
        var outputs: [Data] = []
        outputs.reserveCapacity(parityCount)
        for row in 0..<parityCount {
            var buffer = [UInt8](repeating: 0, count: shardLength)
            for (col, shard) in dataShards.enumerated() {
                mulAdd(into: &buffer, source: shard, coefficient: cauchyCoefficient(parityRow: row, dataColumn: col))
            }
            outputs.append(Data(buffer))
        }
        return outputs
    }

    /// Reconstructs all missing data shards (each of `shardLength` padded bytes) when enough parity shards have arrived.
    /// Returns `nil` if more shards are still needed.
    public static func reconstructMissingDataShards(
        dataShards: [Data?],
        parityShards: [Int: Data],
        shardLength: Int,
        parityCount: Int
    ) throws -> [Int: [UInt8]]? {
        let dataCount = dataShards.count
        guard (2...maximumDataShards).contains(dataCount),
              (1...maximumParityShards).contains(parityCount),
              shardLength > 0 else {
            throw DeskError.invalid("分块纠错恢复参数无效")
        }
        var missingColumns: [Int] = []
        for (col, shard) in dataShards.enumerated() {
            if let shard {
                guard shard.count <= shardLength else {
                    throw DeskError.invalid("分块纠错源分片长度超限")
                }
            } else {
                missingColumns.append(col)
            }
        }
        let missingCount = missingColumns.count
        if missingCount == 0 { return [:] }

        let availableParityRows = parityShards.keys
            .filter { (0..<parityCount).contains($0) }
            .sorted()
        guard availableParityRows.count >= missingCount else {
            return nil
        }

        let chosenParityRows = Array(availableParityRows.prefix(missingCount))
        var rhs: [[UInt8]] = []
        rhs.reserveCapacity(missingCount)
        for parityRow in chosenParityRows {
            guard let parityData = parityShards[parityRow], parityData.count == shardLength else {
                throw DeskError.invalid("分块纠错校验片长度不匹配")
            }
            var residual = [UInt8](parityData)
            for (col, maybeShard) in dataShards.enumerated() {
                guard let knownShard = maybeShard else { continue }
                mulAdd(into: &residual, source: knownShard, coefficient: cauchyCoefficient(parityRow: parityRow, dataColumn: col))
            }
            rhs.append(residual)
        }

        var submatrix = [UInt8](repeating: 0, count: missingCount * missingCount)
        for (rowIdx, parityRow) in chosenParityRows.enumerated() {
            for (colIdx, missingCol) in missingColumns.enumerated() {
                submatrix[rowIdx * missingCount + colIdx] = cauchyCoefficient(parityRow: parityRow, dataColumn: missingCol)
            }
        }
        let inverted = try invertMatrix(submatrix, size: missingCount)

        var recovered: [Int: [UInt8]] = [:]
        recovered.reserveCapacity(missingCount)
        for (targetIdx, missingCol) in missingColumns.enumerated() {
            var shardBytes = [UInt8](repeating: 0, count: shardLength)
            for equationIdx in 0..<missingCount {
                let coeff = inverted[targetIdx * missingCount + equationIdx]
                mulAdd(into: &shardBytes, source: rhs[equationIdx], coefficient: coeff)
            }
            recovered[missingCol] = shardBytes
        }
        return recovered
    }
}

public enum BlockFECPlanner {
    public static let maximumProtectedFrameFragments = 256
    public static let maximumBlockDataCount = 10
    public static let maximumParityCount = 3

    public struct BlockDescriptor: Equatable, Sendable {
        public let start: Int
        public let dataCount: Int
        public let parityCount: Int

        public init(start: Int, dataCount: Int, parityCount: Int) {
            self.start = start
            self.dataCount = dataCount
            self.parityCount = parityCount
        }
    }

    /// Splits `fragmentCount` (`2...256`) into balanced blocks of at most `maximumBlockDataCount` fragments.
    public static func partition(fragmentCount: Int, parityPerBlock: Int) -> [BlockDescriptor] {
        guard (2...maximumProtectedFrameFragments).contains(fragmentCount),
              (1...maximumParityCount).contains(parityPerBlock) else {
            return []
        }
        let blockCount = (fragmentCount + maximumBlockDataCount - 1) / maximumBlockDataCount
        let baseSize = fragmentCount / blockCount
        let remainder = fragmentCount % blockCount
        var blocks: [BlockDescriptor] = []
        blocks.reserveCapacity(blockCount)
        var cursor = 0
        for blockIdx in 0..<blockCount {
            let count = baseSize + (blockIdx < remainder ? 1 : 0)
            let clampedParity = min(parityPerBlock, max(1, count - 1))
            blocks.append(BlockDescriptor(start: cursor, dataCount: count, parityCount: clampedParity))
            cursor += count
        }
        return blocks
    }
}
