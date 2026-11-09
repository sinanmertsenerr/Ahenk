import Foundation

/// Who may open the local WebSocket: only the Ahenk browser extension.
///
/// Browsers set a WebSocket's `Origin` header themselves and a page cannot
/// change it, so checking it keeps every web page (and a DNS-rebinding
/// trick that points some host name at 127.0.0.1) away from what the user
/// listens to and from the player's controls:
///
/// - Chromium browsers (Chrome, Edge, Brave, Arc, Opera, Vivaldi) name the
///   extension `chrome-extension://<id>`; the ID is fixed by the public key
///   in `Extension/manifest.json`, so only that ID is accepted. (Edge shows
///   `extension://` in its address bar; that form is accepted for the same
///   ID.)
/// - The Search browser runs Chrome extensions on WebKit and gives a folder
///   loaded unpacked its own ID, `chrome-extension://local-<8 hex digits>`
///   (it ignores the manifest's key), so that form is accepted.
/// - Firefox gives every installation its own random `moz-extension://<uuid>`
///   and WebKit browsers `webkit-extension://<uuid>`, so any well-formed one
///   is accepted.
/// - The `Host` header must name the loopback address Ahenk listens on.
public struct BridgeOriginPolicy: Sendable, Equatable {
    /// The Chromium extension ID derived from the manifest's `key`.
    public static let extensionID = "goajefoldohohgnmcfkpkembdpjbpfde"

    public enum Origin: Sendable, Equatable {
        case chromium(extensionID: String)
        /// An unpacked extension in a WebKit browser that runs Chrome
        /// extensions (Search: `local-1a2b3c4d`).
        case unpacked(id: String)
        case firefox(uuid: String)
        case webKit(uuid: String)
    }

    public enum Decision: Sendable, Equatable {
        case accept(Origin)
        case reject(String)

        public var isAccepted: Bool {
            if case .accept = self { return true }
            return false
        }
    }

    public var chromiumExtensionIDs: Set<String>
    /// Firefox's and WebKit's per-installation origins, and Search's
    /// unpacked IDs.
    public var acceptsRandomIDs: Bool

    public init(chromiumExtensionIDs: Set<String> = [BridgeOriginPolicy.extensionID], acceptsRandomIDs: Bool = true) {
        self.chromiumExtensionIDs = chromiumExtensionIDs
        self.acceptsRandomIDs = acceptsRandomIDs
    }

    public static let standard = BridgeOriginPolicy()

    /// Judges a handshake from its headers (names compared without case).
    public func evaluate(headers: [(name: String, value: String)]) -> Decision {
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        return evaluate(origin: header("Origin"), host: header("Host"))
    }

    public func evaluate(origin rawOrigin: String?, host: String?) -> Decision {
        guard let host, Self.isLoopbackHost(host) else { return .reject("host is not the loopback address") }
        guard let rawOrigin = rawOrigin?.trimmingCharacters(in: .whitespaces), !rawOrigin.isEmpty else {
            return .reject("no origin")
        }
        let origin = rawOrigin.hasSuffix("/") ? String(rawOrigin.dropLast()) : rawOrigin
        for scheme in ["chrome-extension://", "extension://"] where origin.hasPrefix(scheme) {
            let id = String(origin.dropFirst(scheme.count))
            if Self.isUnpackedID(id) {
                return acceptsRandomIDs ? .accept(.unpacked(id: id)) : .reject("unpacked extensions are not accepted")
            }
            guard Self.isChromiumID(id) else { return .reject("malformed extension origin") }
            guard chromiumExtensionIDs.contains(id) else { return .reject("another extension") }
            return .accept(.chromium(extensionID: id))
        }
        for scheme in ["moz-extension://", "webkit-extension://", "safari-web-extension://"] where origin.hasPrefix(scheme) {
            let uuid = String(origin.dropFirst(scheme.count))
            guard acceptsRandomIDs else { return .reject("per-installation origins are not accepted") }
            guard UUID(uuidString: uuid) != nil else { return .reject("malformed extension origin") }
            return .accept(scheme == "moz-extension://" ? .firefox(uuid: uuid.lowercased()) : .webKit(uuid: uuid.lowercased()))
        }
        return .reject("not an extension origin")
    }

    /// 32 letters from a to p (Chromium's alphabet for extension IDs).
    static func isChromiumID(_ id: String) -> Bool {
        id.count == 32 && id.unicodeScalars.allSatisfy { ("a"..."p").contains($0) }
    }

    /// `local-` and 8 lowercase hex digits (Search's unpacked extensions).
    static func isUnpackedID(_ id: String) -> Bool {
        guard id.hasPrefix("local-") else { return false }
        let digits = id.dropFirst("local-".count)
        return digits.count == 8 && digits.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `127.0.0.1`, `localhost` or `[::1]`, with or without a port.
    static func isLoopbackHost(_ host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("[") {
            guard let close = name.firstIndex(of: "]") else { return false }
            let rest = name[name.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && Int(rest.dropFirst()) != nil) else { return false }
            name = String(name[name.index(after: name.startIndex)..<close])
            return name == "::1"
        }
        if let colon = name.lastIndex(of: ":") {
            guard Int(name[name.index(after: colon)...]) != nil else { return false }
            name = String(name[..<colon])
        }
        return name == "127.0.0.1" || name == "localhost"
    }

    /// The extension ID Chromium derives from a manifest `key` (base64 of
    /// the DER public key): the first 128 bits of its SHA-256, each hex
    /// digit mapped onto a…p.
    public static func chromiumID(fromPublicKeyDigest digest: some Sequence<UInt8>) -> String {
        let hex = digest.prefix(16).flatMap { [$0 >> 4, $0 & 0x0F] }
        return String(hex.map { Character(Unicode.Scalar(UInt8(ascii: "a") + $0)) })
    }
}
