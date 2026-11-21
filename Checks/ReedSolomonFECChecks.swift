import Foundation
import QuietDeskCore

func runReedSolomonFECChecks() {
    run("ReedSolomonGF256 Cauchy MDS matrix inverts every 1-, 2-, 3- and 4-erasure combination across 10 shards") {
        let shardLen = 193 // odd length matching arbitrary NAL payload alignment
        let dataShards: [Data] = (0..<10).map { col in
            let len = col == 9 ? 71 : shardLen
            return Data((0..<len).map { idx in UInt8((col * 37 + idx * 13 + 7) & 0xFF) })
        }
        let parities = try ReedSolomonGF256.encodeParityShards(dataShards: dataShards, shardLength: shardLen, parityCount: 4)
        try check(parities.count == 4 && parities.allSatisfy { $0.count == shardLen }, "Unexpected parity shard count or length")

        // Exhaustively test every 3-missing-shard burst/scatter pattern across 10 data shards (120 combinations) using non-contiguous parity rows [0, 2, 3].
        let parityMap: [Int: Data] = [0: parities[0], 2: parities[2], 3: parities[3]]
        for i in 0..<8 {
            for j in (i + 1)..<9 {
                for k in (j + 1)..<10 {
                    var received: [Data?] = dataShards.map { Optional($0) }
                    received[i] = nil
                    received[j] = nil
                    received[k] = nil
                    guard let recovered = try ReedSolomonGF256.reconstructMissingDataShards(
                        dataShards: received,
                        parityShards: parityMap,
                        shardLength: shardLen,
                        parityCount: 4
                    ) else {
                        throw CheckFailure("Failed to reconstruct 3 missing shards (\(i), \(j), \(k))")
                    }
                    for missingCol in [i, j, k] {
                        guard let raw = recovered[missingCol] else {
                            throw CheckFailure("Missing recovered column \(missingCol)")
                        }
                        let expected = dataShards[missingCol]
                        try check(Data(raw.prefix(expected.count)) == expected,
                                  "Recovered bytes mismatch at column \(missingCol) for pattern (\(i),\(j),\(k))")
                        if expected.count < shardLen {
                            try check(raw[expected.count..<shardLen].allSatisfy { $0 == 0 },
                                      "Recovered padded tail was non-zero at column \(missingCol)")
                        }
                    }
                }
            }
        }

        // Verify 4 simultaneous burst erasures [3, 4, 5, 6] with all 4 parity shards.
        let fullParityMap: [Int: Data] = [0: parities[0], 1: parities[1], 2: parities[2], 3: parities[3]]
        var fourDropped: [Data?] = dataShards.map { Optional($0) }
        for idx in 3...6 { fourDropped[idx] = nil }
        let fourRecovered = try ReedSolomonGF256.reconstructMissingDataShards(
            dataShards: fourDropped,
            parityShards: fullParityMap,
            shardLength: shardLen,
            parityCount: 4
        )
        try check(fourRecovered?.count == 4, "4-erasure recovery failed")
        for idx in 3...6 {
            try check(Data(fourRecovered![idx]!) == dataShards[idx], "4-erasure mismatch at shard \(idx)")
        }

        // Insufficient parity returns nil cleanly without throwing.
        let insufficient = try ReedSolomonGF256.reconstructMissingDataShards(
            dataShards: fourDropped,
            parityShards: [0: parities[0], 1: parities[1]],
            shardLength: shardLen,
            parityCount: 4
        )
        try check(insufficient == nil, "Insufficient parity should return nil while awaiting more fragments")
    }

    run("BlockFECPlanner partitions large frames into balanced blocks within 2...10 fragments") {
        let split14 = BlockFECPlanner.partition(fragmentCount: 14, parityPerBlock: 2)
        try check(
            split14 == [
                .init(start: 0, dataCount: 7, parityCount: 2),
                .init(start: 7, dataCount: 7, parityCount: 2)
            ],
            "14-fragment partition was unbalanced: \(split14)"
        )
        let split25 = BlockFECPlanner.partition(fragmentCount: 25, parityPerBlock: 3)
        try check(
            split25 == [
                .init(start: 0, dataCount: 9, parityCount: 3),
                .init(start: 9, dataCount: 8, parityCount: 3),
                .init(start: 17, dataCount: 8, parityCount: 3)
            ],
            "25-fragment partition was unbalanced: \(split25)"
        )
        let split2 = BlockFECPlanner.partition(fragmentCount: 2, parityPerBlock: 3)
        try check(split2 == [.init(start: 0, dataCount: 2, parityCount: 1)],
                  "2-fragment block did not clamp parity count to dataCount - 1")
        try check(BlockFECPlanner.partition(fragmentCount: 1, parityPerBlock: 1).isEmpty,
                  "1-fragment frame should not use block FEC")
        // Frames beyond the 256 fragments older viewers accept are planned up to the advertised limit.
        let large = BlockFECPlanner.partition(fragmentCount: 1_725, parityPerBlock: 2)
        try check(large.count == 173 && large.reduce(0) { $0 + $1.dataCount } == 1_725
                  && large.allSatisfy { (9...10).contains($0.dataCount) && $0.parityCount == 2 }
                  && zip(large, large.dropFirst()).allSatisfy { $0.start + $0.dataCount == $1.start },
                  "A native-resolution keyframe was not split into contiguous balanced blocks")
        try check(BlockFECPlanner.legacyProtectedFrameFragments == 256
                  && BlockFECPlanner.partition(fragmentCount: BlockFECPlanner.maximumProtectedFrameFragments + 1, parityPerBlock: 1).isEmpty,
                  "The block FEC frame limits changed")
    }
}
