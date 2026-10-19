import Foundation
import QuietDeskCore

func runRelayProtocolChecks() {
    run("Relay addresses normalize without permitting credentials, paths or plaintext schemes") {
        let first = try RelayEndpoint(address: "relay.example.COM:443")
        let second = try RelayEndpoint(address: "tls://relay.example.com:443")
        try check(first == second && first.credentialAccount == second.credentialAccount, "Equivalent relay nodes changed credential identity")
        try check(try RelayEndpoint(address: "tls://[::1]:7443").address == "tls://[::1]:7443", "IPv6 relay address changed")
        let encoded = try JSONEncoder().encode(first)
        try check(try JSONDecoder().decode(RelayEndpoint.self, from: encoded) == first, "Saved relay node changed")
        for address in ["", "http://relay.example.com", "tls://user:secret@relay.example.com", "tls://relay.example.com/path",
                        "tls://relay.example.com?secret=value", "tls://relay.example.com:0", "tls://relay.example.com:65536",
                        "tls://relay%40other.example.com", "tls://relay%2fother.example.com"] {
            try rejects("Invalid relay endpoint accepted") { _ = try RelayEndpoint(address: address) }
        }
    }
    run("Relay framed messages bind required fields and reject invalid or oversized routing material") {
        let original = RelayMessage(.incoming, circuitID: String(repeating: "a", count: 64))
        let framed = try original.framed()
        var prefix = ByteReader(Data(framed.prefix(4)))
        let length: UInt32 = try prefix.take()
        let decoded = try RelayMessage.decode(Data(framed.dropFirst(4)))
        try check(Int(length) == framed.count - 4 && decoded.circuitID == original.circuitID, "Relay framing changed")
        for message in [RelayMessage(.register), RelayMessage(.registered), RelayMessage(.incomingDatagram),
                        RelayMessage(.connect, accessKey: Data(count: 31), deviceID: UUID()),
                        RelayMessage(.incoming, circuitID: String(repeating: "g", count: 64))] {
            try rejects("Malformed relay message accepted") { _ = try message.framed() }
        }
        try rejects("Oversized relay body accepted") { _ = try RelayMessage.decode(Data(count: RelayMessage.maximumBytes + 1)) }
        try rejects("Unknown relay version accepted") { _ = try RelayMessage.decode(Data(#"{"version":2,"op":"ready"}"#.utf8)) }
        try rejects("Unknown server error reflected into the UI") { _ = try RelayMessage.decode(Data(#"{"version":1,"op":"error","error":"untrusted text"}"#.utf8)) }
        try check(!RelayServiceError.unauthorized.retryable && !RelayServiceError.ownerMismatch.retryable && RelayServiceError.offline.retryable,
                  "Fatal authentication errors became endless retries")
    }
    run("Relay datagrams match the server wire vector and reject every modified byte") {
        let key = Data(0..<32), id = Data(0..<16)
        let packet = try RelayDatagram(side: 1, downstream: true, sequence: 17, id: id, payload: Data([0, 128, 255]))
        let encoded = try packet.encode(key: key)
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        try check(hex == "5144523101010000000000000011000102030405060708090a0b0c0d0e0f00030080ff237a249d00e804b083a7d4c2647df028d8d3ce3bca945417f8517a1935c6cd9e", "Client/server authenticated wire contract diverged")
        let decoded = try RelayDatagram.decode(encoded, key: key)
        try check(decoded.id == id && decoded.sequence == 17 && decoded.downstream && decoded.payload == packet.payload, "Datagram metadata changed")
        for index in encoded.indices {
            var damaged = encoded; damaged[index] ^= 1
            try rejects("Modified routing or payload authenticated") { _ = try RelayDatagram.decode(damaged, key: key) }
        }
        try rejects("Wrong routing key authenticated") { _ = try RelayDatagram.decode(encoded, key: Data(repeating: 1, count: 32)) }
        try rejects("Unbounded UDP payload accepted") {
            _ = try RelayDatagram(side: 0, sequence: 1, id: id, payload: Data(count: RelayDatagram.maximumPayloadBytes + 1))
        }
    }
    run("Relay replay windows allow bounded reordering but never duplicate, zero or wrapped counters") {
        var window = RelayReplayWindow()
        for value: UInt64 in [1, 3, 2, 64, 65] { try check(window.accept(value), "Fresh reordered datagram rejected") }
        for value: UInt64 in [0, 1, 2, 3, 65] { try check(!window.accept(value), "Replay revived an old relay packet") }
        try check(window.accept(.max) && !window.accept(1) && !window.accept(.max), "Counter exhaustion silently wrapped")
    }
}
