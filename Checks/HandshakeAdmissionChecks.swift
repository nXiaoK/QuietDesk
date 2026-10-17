import Foundation
import QuietDeskCore

func runHandshakeAdmissionChecks() {
    run("Pending handshake reservations are bounded before dispatch and release is idempotent") {
        let gate = PendingHandshakeGate()
        let reservations = Box<[UUID]>([])
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if let id = gate.reserve(address: "192.0.2.\(index)", now: 1) { reservations.update { $0.append(id) } }
        }
        try check(reservations.read().count == 4, "Concurrent callbacks exceeded the pending limit")
        for id in reservations.read() { gate.release(id); gate.release(id) }
        for index in 0..<4 {
            try check(gate.reserve(address: "198.51.100.\(index)", now: 2) != nil, "Released slots were not reusable")
        }
        try check(gate.reserve(address: nil, now: 2) == nil, "Repeated release admitted extra connections")
    }
    run("Handshake admission bounds pending connections and rates each endpoint separately") {
        var policy = HandshakeAdmissionPolicy()
        for count in 0..<4 {
            try check(policy.allows(address: "192.0.2.\(count)", pendingCount: count, now: 10), "Available handshake slot was refused")
        }
        try check(!policy.allows(address: "192.0.2.4", pendingCount: 4, now: 10), "Fifth pending handshake was admitted")
        try check(policy.allows(address: nil, pendingCount: 3, now: 10), "Unknown endpoint should retain global admission")
        try check(!policy.allows(address: nil, pendingCount: 4, now: 10), "Unknown endpoint bypassed global limit")

        var rate = HandshakeAdmissionPolicy()
        for time in [10.0, 11, 12] {
            try check(rate.allows(address: "2001:db8::1", pendingCount: 0, now: time), "First three attempts were refused")
        }
        try check(!rate.allows(address: "2001:db8::1", pendingCount: 0, now: 19.9), "Fourth attempt bypassed IP limit")
        try check(rate.allows(address: "2001:db8::2", pendingCount: 0, now: 19.9), "Another address shared the IP limit")
        try check(rate.allows(address: "2001:db8::1", pendingCount: 0, now: 20), "Attempt did not expire at ten seconds")
        try check(!rate.allows(address: "2001:db8::1", pendingCount: 0, now: 20.5), "Unexpired attempts were forgotten")
        try check(rate.allows(address: "2001:db8::1", pendingCount: 0, now: 21), "Rejected attempts extended the rate-limit window")
        try check(rate.allows(address: "2001:db8::1", pendingCount: 0, now: 32), "Stale endpoint history did not expire")
    }

    run("Handshake admission does not consume IP attempts while globally full or accept invalid clocks") {
        var policy = HandshakeAdmissionPolicy()
        try check(!policy.allows(address: "192.0.2.1", pendingCount: 4, now: 1), "Full admission passed")
        for _ in 0..<3 {
            try check(policy.allows(address: "192.0.2.1", pendingCount: 0, now: 2), "Full admission consumed an IP attempt")
        }
        try check(!policy.allows(address: "192.0.2.1", pendingCount: 0, now: 2), "Fourth real attempt passed")
        for invalidTime in [-1.0, .nan, .infinity, 1] {
            try check(!policy.allows(address: "192.0.2.2", pendingCount: 0, now: invalidTime), "Invalid or backwards clock bypassed admission")
        }
        try check(!policy.allows(address: "192.0.2.2", pendingCount: -1, now: 3), "Negative pending count bypassed admission")
    }
}
