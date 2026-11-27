import Synchronization

/// https://github.com/swiftlang/swift-experimental-string-processing/issues/792
/// https://forums.swift.org/t/should-regex-be-sendable/69529
public struct CaseInsensitiveRegex: Equatable, Sendable {
    public let origin: String
    /// `Regex` isn't `Sendable`: it's used under the lock
    fileprivate let regex: SharedRegex

    private init(_ origin: String, _ regex: SharedRegex) {
        self.origin = origin
        self.regex = regex
    }

    public static func new(_ str: String) -> ResOrStr<CaseInsensitiveRegex> {
        Result { try SharedRegex(caseInsensitive: str) }
            .mapError { e in "Can't parse \(str.singleQuoted) regex: \(e.localizedDescription)" }
            .map { CaseInsensitiveRegex(str, $0) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.origin == rhs.origin }
}

private final class SharedRegex: Sendable {
    private let regex: Mutex<Regex<AnyRegexOutput>>
    /// The regex is made here, so nothing else holds it
    init(caseInsensitive pattern: String) throws { regex = Mutex(try Regex(pattern).ignoresCase()) }
    func isContained(in string: String) -> Bool { regex.withLock { string.contains($0) } }
}

extension String {
    public func contains(caseInsensitiveRegex regex: CaseInsensitiveRegex) -> Bool {
        regex.regex.isContained(in: self)
    }
}
