import Foundation
import Security
@testable import QuietDeskCore

private struct CheckFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(message: message) } }
private func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message: message)
}

@main private struct RelayCertificateChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let pem = try Data(contentsOf: directory.appendingPathComponent("certificate.pem"))
            let der = try Data(contentsOf: directory.appendingPathComponent("certificate.der"))
            let certificate = try RelayNodeCertificate(data: pem)
            let endpoint = try RelayEndpoint(address: "tls://127.0.0.1:7443")
            print("Relay certificate checks on \(ProcessInfo.processInfo.operatingSystemVersionString)")
            run("Bounded PEM/DER imports produce the same OpenSSL SHA-256 fingerprint") {
                try require(certificate == RelayNodeCertificate(data: der), "PEM and DER differ")
                let expected = try String(contentsOf: directory.appendingPathComponent("fingerprint.txt"))
                try require(expected.contains(certificate.fingerprint), "Fingerprint differs from OpenSSL")
                for data in [Data(), Data(repeating: 0, count: RelayNodeCertificate.maximumBytes + 1), pem + pem,
                             Data("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----".utf8),
                             try Data(contentsOf: directory.appendingPathComponent("privkey.pem"))] {
                    try reject("Malformed, oversized, bundled or private data was accepted") { _ = try RelayNodeCertificate(data: data) }
                }
            }
            run("Pinned evaluation recovers from failed system trust for IP and DNS nodes") {
                let leaf = SecCertificateCreateWithData(nil, der as CFData)!
                for address in ["tls://127.0.0.1:7443", "tls://[::1]:7443", "tls://localhost:7443"] {
                    let node = try RelayEndpoint(address: address)
                    var trust: SecTrust?
                    try require(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, node.host as CFString), &trust) == errSecSuccess,
                                "Cannot create trust for \(address)")
                    let supplied = trust!
                    try require(SecTrustSetNetworkFetchAllowed(supplied, false) == errSecSuccess, "Cannot disable network fetching")
                    try require(!SecTrustEvaluateWithError(supplied, nil), "Synthetic node unexpectedly has system trust")
                    if !certificate.evaluate(supplied, endpoint: node) {
                        var error: CFError?
                        _ = SecTrustEvaluateWithError(supplied, &error)
                        throw CheckFailure(message: "Pinned evaluation rejected \(address): \(String(describing: error)); \(String(describing: SecTrustCopyResult(supplied)))")
                    }
                }
            }
            run("A self-signed non-CA node still requires matching IP/DNS and valid dates") {
                try certificate.validate(for: endpoint)
                try certificate.validate(for: RelayEndpoint(address: "tls://[::1]:7443"))
                try certificate.validate(for: RelayEndpoint(address: "tls://localhost:7443"))
                try reject("Another IP was accepted") { try certificate.validate(for: RelayEndpoint(address: "tls://127.0.0.2:7443")) }
                try reject("Another hostname was accepted") { try certificate.validate(for: RelayEndpoint(address: "tls://other.invalid:7443")) }
                try reject("Expired anchor was accepted") { try certificate.validate(for: endpoint, at: .distantFuture) }
                try reject("Not-yet-valid anchor was accepted") { try certificate.validate(for: endpoint, at: .distantPast) }
                let client = try RelayNodeCertificate(data: Data(contentsOf: directory.appendingPathComponent("client.pem")))
                try reject("Client-only certificate was accepted for a server") { try client.validate(for: endpoint) }
            }
            run("A valid chain anchored by the saved certificate cannot replace its exact leaf") {
                let issuer = try RelayNodeCertificate(data: Data(contentsOf: directory.appendingPathComponent("issuer.pem")))
                let issued = try Data(contentsOf: directory.appendingPathComponent("issued.der"))
                let leaf = SecCertificateCreateWithData(nil, issued as CFData)!
                let anchor = SecCertificateCreateWithData(nil, issuer.der as CFData)!
                var trust: SecTrust?
                try require(SecTrustCreateWithCertificates([leaf, anchor] as CFArray, SecPolicyCreateSSL(true, endpoint.host as CFString), &trust) == errSecSuccess,
                            "Cannot create issued chain trust")
                let supplied = trust!
                try require(SecTrustSetAnchorCertificates(supplied, [anchor] as CFArray) == errSecSuccess &&
                            SecTrustSetAnchorCertificatesOnly(supplied, true) == errSecSuccess &&
                            SecTrustSetNetworkFetchAllowed(supplied, false) == errSecSuccess, "Cannot configure issued chain trust")
                try require(SecTrustEvaluateWithError(supplied, nil), "Issued chain does not have valid server trust")
                try require(!issuer.evaluate(supplied, endpoint: endpoint), "A valid chain bypassed the exact certificate pin")
            }
            run("Saved trust survives reload and is isolated by normalized node and port") {
                let suite = "quietdesk.synthetic-certificate-check." + UUID().uuidString
                guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure(message: "Cannot create isolated preferences") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = RelayCertificateStore(defaults: defaults)
                try require(try store.load(for: endpoint) == nil, "New node had implicit trust")
                try store.save(certificate, for: endpoint)
                let reloaded = RelayCertificateStore(defaults: UserDefaults(suiteName: suite)!)
                try require(try reloaded.load(for: RelayEndpoint(address: "127.0.0.1:7443")) == certificate, "Trust was not saved")
                let otherPort = try RelayEndpoint(address: "127.0.0.1:7444")
                try require(try store.load(for: otherPort) == nil, "Trust crossed node ports")
                try require(try store.load(for: RelayEndpoint(address: "127.0.0.2:7443")) == nil, "Trust crossed IPs")
                try store.save(certificate, for: otherPort)
                try store.save(nil, for: endpoint)
                try require(try store.load(for: endpoint) == nil && store.load(for: otherPort) == certificate, "Removing trust changed another node")
                defaults.set("corrupt", forKey: endpoint.credentialAccount + ".certificate")
                try reject("Damaged trust silently reverted to system trust") { _ = try store.load(for: endpoint) }
                defaults.set(Data([0, 1, 2]), forKey: endpoint.credentialAccount + ".certificate")
                try reject("Invalid saved certificate silently reverted to system trust") { _ = try store.load(for: endpoint) }
            }
        } catch { failed += 1; print("FAIL certificate fixture: \(error)") }
        print("Relay certificate checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
