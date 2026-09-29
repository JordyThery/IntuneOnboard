import Foundation

/// A `deviceNameTemplate`: literal text with `%token%` substitutions, an
/// optional modifier per token, and `%%` for a literal percent sign.
/// Invalid templates are rejected when the configuration is parsed.
public struct NameTemplate: Equatable, Sendable {
    public enum Token: String, Equatable, Sendable, CaseIterable {
        case serial
        case udid
        case model
        /// First word of the model, e.g. "MacBook" for a MacBook Air.
        case modelShort = "model-short"
    }

    /// `:n` first n characters, `:-n` last n, `:=n` middle n.
    public enum Modifier: Equatable, Sendable {
        case first(Int)
        case last(Int)
        case center(Int)

        func apply(to value: String) -> String {
            switch self {
            case .first(let n): String(value.prefix(n))
            case .last(let n): String(value.suffix(n))
            case .center(let n):
                if value.count <= n {
                    value
                } else {
                    // An odd surplus is taken from the end.
                    String(Array(value)[((value.count - n) / 2)...].prefix(n))
                }
            }
        }
    }

    public enum Segment: Equatable, Sendable {
        case literal(String)
        case token(Token, Modifier?)
    }

    public let raw: String
    public let segments: [Segment]

    // MARK: - Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unterminatedToken
        case unknownToken(String)
        case invalidModifier(String)

        public var description: String {
            switch self {
            case .empty:
                "the template is empty"
            case .unterminatedToken:
                "a % starts a token that never ends (write %% for a literal %)"
            case .unknownToken(let name):
                "unknown token %\(name)% — available: "
                    + Token.allCases.map { "%\($0.rawValue)%" }.joined(separator: ", ")
            case .invalidModifier(let text):
                "invalid modifier :\(text) — use :n (first n), :-n (last n) or :=n (center n)"
            }
        }
    }

    public static func parse(_ raw: String) throws -> NameTemplate {
        guard !raw.isEmpty else { throw ParseError.empty }

        var segments: [Segment] = []
        var literal = ""
        var rest = Substring(raw)

        func flushLiteral() {
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
        }

        while let character = rest.first {
            rest = rest.dropFirst()
            guard character == "%" else {
                literal.append(character)
                continue
            }
            if rest.first == "%" {
                literal.append("%")
                rest = rest.dropFirst()
                continue
            }
            guard let end = rest.firstIndex(of: "%") else {
                throw ParseError.unterminatedToken
            }
            let body = rest[..<end]
            rest = rest[rest.index(after: end)...]

            let name = String(body.prefix { $0 != ":" })
            guard let token = Token(rawValue: name) else {
                throw ParseError.unknownToken(name)
            }
            var modifier: Modifier?
            if let colon = body.firstIndex(of: ":") {
                let spec = String(body[body.index(after: colon)...])
                modifier = try parseModifier(spec)
            }
            flushLiteral()
            segments.append(.token(token, modifier))
        }
        flushLiteral()
        return NameTemplate(raw: raw, segments: segments)
    }

    private static func parseModifier(_ spec: String) throws -> Modifier {
        if spec.hasPrefix("-"), let n = Int(spec.dropFirst()), n > 0 {
            return .last(n)
        }
        if spec.hasPrefix("="), let n = Int(spec.dropFirst()), n > 0 {
            return .center(n)
        }
        if let n = Int(spec), n > 0 {
            return .first(n)
        }
        throw ParseError.invalidModifier(spec)
    }

    // MARK: - Rendering

    /// The rendered name, or nil if any token has no value.
    public func render(value: (Token) -> String?) -> String? {
        var result = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                result += text
            case .token(let token, let modifier):
                guard let raw = value(token), !raw.isEmpty else { return nil }
                result += modifier.map { $0.apply(to: raw) } ?? raw
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - LocalHostName

    /// A Bonjour-safe host name: ASCII letters, digits and single hyphens, at
    /// most 63 characters. Spaces and underscores become hyphens; other
    /// characters are dropped. nil if nothing remains.
    public static func localHostName(from name: String) -> String? {
        var sanitized = ""
        var previousWasHyphen = false
        for character in name {
            if character.isASCII, character.isLetter || character.isNumber {
                sanitized.append(character)
                previousWasHyphen = false
            } else if character == "-" || character == " " || character == "_" {
                if !previousWasHyphen, !sanitized.isEmpty {
                    sanitized.append("-")
                    previousWasHyphen = true
                }
            }
        }
        // Truncate first; truncation can leave a trailing hyphen.
        var trimmed = String(sanitized.prefix(63))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}
