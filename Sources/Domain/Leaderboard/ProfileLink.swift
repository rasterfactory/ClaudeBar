import Foundation

/// *PROFILE LINK* — one place on X, Instagram or GitHub where people on the
/// board can find a member. Only a handle is held; the address is always
/// the platform's own, so a link can't point anywhere else. Handles follow
/// each platform's username rules, pinned by `vectors.json`, which the
/// server checks too. Not verified: anyone can type any handle.
public struct ProfileLink: Sendable, Hashable, Codable {
    public enum Platform: String, Sendable, CaseIterable, Codable {
        case x, instagram, github

        public var name: String {
            switch self {
            case .x: "X"
            case .instagram: "Instagram"
            case .github: "GitHub"
            }
        }

        /// What the address reads as before the handle: `github.com/`.
        public var prefix: String {
            switch self {
            case .x: "x.com/"
            case .instagram: "instagram.com/"
            case .github: "github.com/"
            }
        }

        /// The platform's own rule, in words, for a form's hint.
        public var rule: String {
            switch self {
            case .x: "1–15 letters, numbers or _"
            case .instagram: "1–30 letters, numbers, . or _"
            case .github: "1–39 letters, numbers or single -"
            }
        }

        fileprivate var pattern: String {
            switch self {
            case .x: #"^[A-Za-z0-9_]{1,15}$"#
            case .instagram: #"^(?!\.)(?!.*\.\.)(?!.*\.$)[A-Za-z0-9._]{1,30}$"#
            case .github: #"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$"#
            }
        }
    }

    public let platform: Platform
    public let handle: String

    /// A link when `handle` fits the platform's rules exactly, as the server
    /// checks them. A form that lets people type `@jack` strips it first.
    public init?(platform: Platform, handle: String) {
        guard handle.range(of: platform.pattern, options: .regularExpression) != nil else { return nil }
        self.platform = platform
        self.handle = handle
    }

    /// What someone typed into a handle field, as a link: spaces and a
    /// leading `@` aren't part of a handle.
    public static func typed(_ text: String, on platform: Platform) -> ProfileLink? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return ProfileLink(platform: platform, handle: trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed)
    }

    public var url: URL { URL(string: "https://" + platform.prefix + handle)! }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let platform = try container.decode(Platform.self, forKey: .platform)
        let handle = try container.decode(String.self, forKey: .handle)
        guard let link = ProfileLink(platform: platform, handle: handle) else {
            throw DecodingError.dataCorruptedError(forKey: .handle, in: container, debugDescription: "Not a \(platform.name) handle")
        }
        self = link
    }

    private enum CodingKeys: String, CodingKey { case platform, handle }
}
