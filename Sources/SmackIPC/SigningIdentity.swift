import CryptoKit
import Foundation
import Security

/// Who signed a piece of code. The helper derives its client requirement from its own
/// identity, and the app picks how to install the helper from its own identity, so both
/// sides read signatures the same way.
public enum SigningIdentity: Equatable, Sendable {
    /// Signed by an Apple-issued certificate (Developer ID, Apple Development, Apple Distribution).
    case team(String)
    /// Signed by a certificate without a Team ID, such as the self-signed `Smack Local Dev`.
    /// The value is the SHA-1 of the leaf certificate, the hash the requirement language uses.
    case certificate(String)
    /// Ad hoc or unsigned: there is no stable signer to pin.
    case adHoc

    public static func current() -> SigningIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return .adHoc
        }
        return identity(of: staticCode)
    }

    public static func of(path: String) -> SigningIdentity {
        guard let staticCode = staticCode(at: path) else { return .adHoc }
        return identity(of: staticCode)
    }

    /// The code directory hash identifies the signed code itself; unlike a file hash it does
    /// not change when identical code is re-signed with a new signing time.
    public static func codeDirectoryHash(atPath path: String) -> Data? {
        guard let staticCode = staticCode(at: path),
              let information = signingInformation(staticCode) else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }

    /// The requirement a client with `identifier` must satisfy to come from the same signer.
    public func requirement(forIdentifier identifier: String) -> String? {
        switch self {
        case .team(let team):
            return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        case .certificate(let hash):
            return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
        case .adHoc:
            return nil
        }
    }

    private static func staticCode(at path: String) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess else {
            return nil
        }
        return staticCode
    }

    private static func signingInformation(_ staticCode: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    private static func identity(of staticCode: SecStaticCode) -> SigningIdentity {
        guard let information = signingInformation(staticCode) else { return .adHoc }
        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .team(team)
        }
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return .adHoc
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return .certificate(digest.map { String(format: "%02X", $0) }.joined())
    }
}
