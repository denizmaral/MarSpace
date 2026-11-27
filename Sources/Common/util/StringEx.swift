import Foundation

public typealias ResOrStr<T> = Result<T, String>
extension String: @retroactive LocalizedError { // Make it possible to use String in Result. todo migrate to self written Result monad
    public var errorDescription: String? { self }
}

// Make it possible to use [String] in Result. todo migrate to self written Result monad
extension Array: @retroactive Error where Element: Error {}
extension Array: @retroactive LocalizedError where Element: LocalizedError {}

extension String {
    public func trim() -> String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func prefixLines(with: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).map { with + $0 }.joined(separator: "\n")
    }

    public var singleQuoted: String { "'" + self + "'" }
    public var doubleQuoted: String { "\"" + self + "\"" }
}

extension [String] {
    public func joinErrors() -> String { // todo reuse in config parsing?
        map { (error: String) -> String in
            error.split(separator: "\n").enumerated().lazy
                .map { (i, line) in
                    i == 0
                        ? "ERROR: " + line
                        : "       " + line
                }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    public func joinTruncating(separator: String, length maxLength: Int, trailing: String = "…") -> String {
        if isEmpty {
            return ""
        }
        var remainingLen = maxLength
        let separatorCount = separator.count
        var result: String = first.orDie()
        for _elem in self.dropFirst() {
            let elemCount = separatorCount + _elem.count
            if remainingLen < elemCount / 2 {
                return result + separator + trailing
            }
            let elem = separator + _elem
            if elemCount < remainingLen {
                result += elem
                remainingLen -= elemCount
            } else {
                return result + elem.prefix(remainingLen) + trailing
            }
        }
        return result
    }
}

extension [[String]] {
    public func toPaddingTable(columnSeparator: String = " | ") -> [String] {
        let pads: [Int] = transposed().map { column in column.lazy.map { $0.count }.max().orDie() }
        return self.map { (row: [String]) in
            zip(row.enumerated(), pads)
                .map { (elem: (Int, String), pad: Int) in
                    elem.0 != row.count - 1 ? elem.1.padding(toLength: pad, withPad: " ", startingAt: 0) : elem.1
                }
                .joined(separator: columnSeparator)
        }
    }
}


extension String {

    public func interpolationTokens<T>(
        interpolationChar: Character,
        ofInterVarType type: T.Type,
    ) -> Result<[InterToken<T>], String> where T: Sendable, T: Equatable, T: CaseIterable, T: RawRepresentable, T.RawValue == String {
        rawInterpolationTokens(interpolationChar: interpolationChar).flatMap { rawTokens in
            var result: [InterToken<T>] = []
            for token in rawTokens {
                switch token {
                    case .literal(let literal):
                        result.append(.literal(literal))
                    case .interVar(let value):
                        switch parseEnum(value, type) {
                            case .success(let interVar): result.append(.interVar(interVar))
                            case .failure(let err): return .failure(err)
                        }
                }
            }
            return .success(result)
        }
    }

    func rawInterpolationTokens(interpolationChar: Character) -> Result<[RawStringInterToken], String> {
        var mode: InterpolationParserState = .stringLiteral
        // The literal or the variable that is read: appended to, not copied with every character
        var text = ""
        var result: [RawStringInterToken] = []
        for char: Character? in (Array(self) + [nil]) {
            switch (mode, char) { // State machine
                case (.stringLiteral, interpolationChar):
                    mode = .interpolationCharEncountered
                case (.stringLiteral, let char?):
                    text.append(char)
                case (.stringLiteral, nil):
                    result.append(.literal(text))
                case (.interpolationCharEncountered, "{"):
                    mode = .interpolationVariable
                    result.append(.literal(text))
                    text = ""
                case (.interpolationCharEncountered, interpolationChar):
                    text.append(interpolationChar)
                case (.interpolationCharEncountered, let char?):
                    mode = .stringLiteral
                    text.append(interpolationChar)
                    text.append(char)
                case (.interpolationCharEncountered, nil):
                    result.append(.literal(text + String(interpolationChar)))
                case (.interpolationVariable, "}"):
                    result.append(.interVar(text))
                    text = ""
                    mode = .stringLiteral
                case (.interpolationVariable, "{"):
                    return .failure("Can't parse '\(text + "{")' inside interpolation (Open curly brace is invalid character)")
                case (.interpolationVariable, interpolationChar):
                    return .failure("Can't parse '\(text + .init(interpolationChar))' inside interpolation ('\(interpolationChar)' is disallowed character)")
                case (.interpolationVariable, let char?):
                    text.append(char)
                case (.interpolationVariable, nil):
                    return .failure("Unbalanced curly braces")
            }
        }
        return .success(result.filter { $0 != .literal("") })
    }
}

public enum InterToken<T>: Equatable, Sendable where T: Equatable, T: Sendable {
    case literal(String)
    case interVar(T) // "interpolation variable"
}

typealias RawStringInterToken = InterToken<String>

/// What `rawInterpolationTokens` reads, its text is kept apart
private enum InterpolationParserState {
    case stringLiteral
    case interpolationCharEncountered
    case interpolationVariable
}
