import Foundation
import QuietDeskCore

// Public certificates are preferences, scoped to an exact normalized node address.
// No system trust or Keychain entries are read or changed.
struct RelayCertificateStore {
    let defaults: UserDefaults

    func load(for endpoint: RelayEndpoint) throws -> RelayNodeCertificate? {
        guard let value = defaults.object(forKey: endpoint.credentialAccount + ".certificate") else { return nil }
        guard let data = value as? Data else { throw DeskError.invalid("已保存的节点证书损坏，请重新导入或核对指纹") }
        return try RelayNodeCertificate(data: data)
    }

    func save(_ certificate: RelayNodeCertificate?, for endpoint: RelayEndpoint) throws {
        if let certificate {
            try certificate.validate(for: endpoint)
            defaults.set(certificate.der, forKey: endpoint.credentialAccount + ".certificate")
        } else { defaults.removeObject(forKey: endpoint.credentialAccount + ".certificate") }
    }
}
