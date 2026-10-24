import CryptoKit
import Foundation

enum UpdateSignature {
    static let publicKey = "m0UbLdp60TGrr4oQs1p3pqNTXQQOqOZM2oRtf3jnJlM="

    static var isConfigured: Bool { !publicKey.isEmpty }

    static func verify(dmg: URL, signatureURL: URL?) async throws {
        guard isConfigured else { return }
        guard let signatureURL, signatureURL.scheme == "https" else { throw UpdateError.unsigned }
        var req = URLRequest(url: signatureURL)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw UpdateError.unsigned }
        let signature = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try await Task.detached { try Data(contentsOf: dmg, options: .mappedIfSafe) }.value
        guard isValid(signature: signature, payload: payload, publicKey: publicKey) else { throw UpdateError.badSignature }
    }

    static func isValid(signature: String, payload: Data, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(sig, for: payload)
    }
}
