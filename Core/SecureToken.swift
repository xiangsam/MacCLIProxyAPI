import Foundation
import Security

enum SecureToken {
    static func generate(length: Int = 32, prefix: String = "") -> String {
        precondition(length > 0)

        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return prefix + String(bytes.map { alphabet[Int($0) % alphabet.count] })
        }

        // SecRandomCopyBytes should be available on macOS. Keep a non-crashing fallback
        // so first launch can still create a configuration in a degraded environment.
        return prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
