import Foundation
import CryptoKit
import Network
import Security

// A node-specific leaf certificate, never a machine-wide trust anchor.
public struct RelayNodeCertificate: Equatable, Sendable {
    public let der: Data
    public static let maximumBytes = 65_536

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw RelayTransportError.certificate }
        let decoded: Data
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
            guard trimmed.hasPrefix(start), trimmed.hasSuffix(end) else { throw RelayTransportError.certificate }
            let body = trimmed.dropFirst(start.count).dropLast(end.count).filter { !$0.isWhitespace }
            guard let value = Data(base64Encoded: String(body)) else { throw RelayTransportError.certificate }
            decoded = value
        } else { decoded = data }
        guard let certificate = SecCertificateCreateWithData(nil, decoded as CFData),
              (SecCertificateCopyData(certificate) as Data) == decoded else { throw RelayTransportError.certificate }
        der = decoded
    }

    public var fingerprint: String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public var expires: Date? { validity(kSecOIDX509V1ValidityNotAfter) }

    private func validity(_ oid: CFString) -> Date? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let property = values[oid as String] as? [String: Any],
              let value = property[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: value.doubleValue)
    }

    public func validate(for endpoint: RelayEndpoint, at date: Date = Date()) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw RelayTransportError.certificate }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, endpoint.host as CFString), &trust) == errSecSuccess,
              let trust, evaluate(trust, endpoint: endpoint, date: date) else { throw RelayTransportError.certificate }
    }

    func evaluate(_ trust: SecTrust, endpoint: RelayEndpoint, date: Date = Date()) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let before = validity(kSecOIDX509V1ValidityNotBefore), let after = expires,
              before <= date, date <= after,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              (SecCertificateCopyData(leaf) as Data) == der,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, endpoint.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

// Reads a candidate certificate, rejects the handshake, and never sends relay credentials.
// Only the settings UI may confirm and persist the returned candidate.
public final class RelayCertificateProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "quietdesk.relay-certificate-probe")
    private var connection: NWConnection?
    private var completion: ((Result<RelayNodeCertificate, Error>) -> Void)?
    private var started = false

    public init(endpoint: RelayEndpoint, completion: @escaping (Result<RelayNodeCertificate, Error>) -> Void) {
        self.completion = completion
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.host)
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 10
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, supplied, complete in
            guard let self else { complete(false); return }
            let result = Result<RelayNodeCertificate, Error> {
                let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                    throw RelayTransportError.certificate
                }
                let certificate = try RelayNodeCertificate(data: SecCertificateCopyData(leaf) as Data)
                try certificate.validate(for: endpoint)
                return certificate
            }
            complete(false)
            self.finish(result)
        }, queue)
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!,
                                  using: NWParameters(tls: tls, tcp: tcp))
    }

    public func start() {
        queue.async { [self] in
            guard !started, completion != nil else { return }; started = true
            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .waiting: self?.finish(.failure(RelayTransportError.network))
                case .cancelled: self?.finish(.failure(RelayTransportError.cancelled))
                default: break
                }
            }
            connection?.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(.failure(RelayTransportError.timeout)) }
        }
    }

    public func cancel() { queue.async { [self] in finish(.failure(RelayTransportError.cancelled)) } }

    private func finish(_ result: Result<RelayNodeCertificate, Error>) {
        guard let callback = completion else { return }; completion = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); callback(result)
    }

    deinit { connection?.cancel() }
}
