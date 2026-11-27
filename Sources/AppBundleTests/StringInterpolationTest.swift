@testable import AppBundle
@testable import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct StringInterpolationTest {
    @Test func testTokens() {
        func tokens(_ string: String) -> Result<[RawStringInterToken], String> { string.rawInterpolationTokens(interpolationChar: "%") }
        #expect(tokens("") == .success([]))
        #expect(tokens("a%{x}b") == .success([.literal("a"), .interVar("x"), .literal("b")]))
        #expect(tokens("%{x}%{y}") == .success([.interVar("x"), .interVar("y")]))
        #expect(tokens("100%") == .success([.literal("100%")]))
        #expect(tokens("%a") == .success([.literal("%a")]))
        #expect(tokens("%%{x}") == .success([.literal("%"), .interVar("x")]))
        #expect(tokens("a%%b") == .success([.literal("a%%b")]))
        #expect(tokens("%{a{") == .failure("Can't parse 'a{' inside interpolation (Open curly brace is invalid character)"))
        #expect(tokens("%{a%") == .failure("Can't parse 'a%' inside interpolation ('%' is disallowed character)"))
        #expect(tokens("%{a") == .failure("Unbalanced curly braces"))
    }
}
