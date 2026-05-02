import Foundation
import Security

/// Thread-safe GCS OAuth2 token provider using service account JWT (RS256).
actor GCSAuthService {
    static let shared = GCSAuthService()

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    // MARK: - Public API

    /// Returns a valid Bearer token, refreshing if needed.
    func accessToken(serviceAccountKeyPath: String) async throws -> String {
        if let token = cachedToken, Date() < tokenExpiry.addingTimeInterval(-300) {
            return token
        }
        let token = try await fetchToken(keyPath: serviceAccountKeyPath)
        cachedToken = token.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        return token.accessToken
    }

    func invalidate() {
        cachedToken = nil
        tokenExpiry = .distantPast
    }

    // MARK: - JWT Construction

    private func fetchToken(keyPath: String) async throws -> TokenResponse {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        guard let json = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let clientEmail = json["client_email"] as? String,
              let privateKeyPEM = json["private_key"] as? String
        else {
            throw GCSAuthError.invalidKeyFile
        }

        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": clientEmail,
            "scope": "https://www.googleapis.com/auth/devstorage.read_write",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600
        ]

        let jwt = try buildJWT(claims: claims, pemKey: privateKeyPEM)
        return try await exchangeJWT(jwt)
    }

    private func buildJWT(claims: [String: Any], pemKey: String) throws -> String {
        let header = ["alg": "RS256", "typ": "JWT"]
        let headerB64 = base64urlEncode(try JSONSerialization.data(withJSONObject: header))
        let claimsB64 = base64urlEncode(try JSONSerialization.data(withJSONObject: claims))
        let signingInput = "\(headerB64).\(claimsB64)"

        let privateKey = try loadPrivateKey(pem: pemKey)
        let signature = try signRS256(data: Data(signingInput.utf8), key: privateKey)
        let sigB64 = base64urlEncode(signature)
        return "\(signingInput).\(sigB64)"
    }

    // MARK: - RSA Key Loading

    private func loadPrivateKey(pem: String) throws -> SecKey {
        // Strip PEM header/footer and whitespace, decode base64 DER
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: stripped) else {
            throw GCSAuthError.invalidKeyFile
        }

        // Service account keys are PKCS#8 (BEGIN PRIVATE KEY). Strip the PKCS#8 header
        // to get the raw RSA key that SecKeyCreateWithData expects.
        let rsaDER = stripPKCS8Header(derData) ?? derData

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(rsaDER as CFData, attributes as CFDictionary, &error) else {
            throw GCSAuthError.keyLoadFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return key
    }

    /// Strips the PKCS#8 AlgorithmIdentifier wrapper from DER data, returning just the RSA key body.
    private func stripPKCS8Header(_ der: Data) -> Data? {
        // PKCS#8 PrivateKeyInfo structure:
        // SEQUENCE {
        //   INTEGER (version = 0)
        //   SEQUENCE { OID rsaEncryption, NULL }
        //   OCTET STRING { RSAPrivateKey }
        // }
        // We walk the DER to find and return the OCTET STRING payload.
        var idx = der.startIndex
        func readByte() -> UInt8? {
            guard idx < der.endIndex else { return nil }
            let b = der[idx]; idx = der.index(after: idx); return b
        }
        func readLength() -> Int? {
            guard let first = readByte() else { return nil }
            if first & 0x80 == 0 { return Int(first) }
            let numBytes = Int(first & 0x7f)
            var length = 0
            for _ in 0..<numBytes {
                guard let b = readByte() else { return nil }
                length = (length << 8) | Int(b)
            }
            return length
        }
        // Outer SEQUENCE
        guard readByte() == 0x30, let _ = readLength() else { return nil }
        // Version INTEGER
        guard readByte() == 0x02, let vLen = readLength() else { return nil }
        idx = der.index(idx, offsetBy: vLen, limitedBy: der.endIndex) ?? der.endIndex
        // AlgorithmIdentifier SEQUENCE
        guard readByte() == 0x30, let algLen = readLength() else { return nil }
        idx = der.index(idx, offsetBy: algLen, limitedBy: der.endIndex) ?? der.endIndex
        // OCTET STRING
        guard readByte() == 0x04, let octetLen = readLength() else { return nil }
        let end = der.index(idx, offsetBy: octetLen, limitedBy: der.endIndex) ?? der.endIndex
        return Data(der[idx..<end])
    }

    // MARK: - RS256 Signing

    private func signRS256(data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw GCSAuthError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return signature
    }

    // MARK: - Token Exchange

    private func exchangeJWT(_ jwt: String) async throws -> TokenResponse {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw GCSAuthError.invalidConfig
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw GCSAuthError.tokenExchangeFailed(msg)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return decoded
    }

    // MARK: - Helpers

    private func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }
}

enum GCSAuthError: LocalizedError {
    case invalidKeyFile
    case keyLoadFailed(String)
    case signingFailed(String)
    case invalidConfig
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidKeyFile: return "Service account key file is missing or invalid."
        case .keyLoadFailed(let msg): return "Failed to load RSA key: \(msg)"
        case .signingFailed(let msg): return "JWT signing failed: \(msg)"
        case .invalidConfig: return "Invalid GCS auth configuration."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        }
    }
}
