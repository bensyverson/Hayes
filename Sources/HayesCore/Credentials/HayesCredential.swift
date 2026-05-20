/// Well-known identifiers for the credentials Hayes stores.
///
/// Centralizing the Keychain service name and account keys here keeps the
/// `auth` command, the credential resolver, and ``KeychainCredentialStore``
/// in agreement on exactly where a secret lives.
public enum HayesCredential {
    /// The Keychain service (a reverse-DNS identifier) under which all Hayes
    /// secrets are grouped.
    public static let service: String = "com.bensyverson.hayes"

    /// The account key for the Anthropic API key used by assess and the
    /// optional Anthropic recall path.
    public static let anthropicAPIKey: String = "anthropic-api-key"
}
