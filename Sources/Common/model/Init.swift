import Synchronization

/// What runs: the unit tests until the binary says otherwise, at its start (`main` of the CLI, `initAppBundle` of the
/// server)
public enum ProcessRole: Sendable {
    case unitTests
    case cli
    case server
}

private let _processRole = Mutex(ProcessRole.unitTests)
public var processRole: ProcessRole {
    get { _processRole.withLock { $0 } }
    set { _processRole.withLock { $0 = newValue } }
}

/// The unit tests too: they show messages on the command line
var isCli: Bool { processRole != .server }
var isServer: Bool { processRole == .server }
public var isUnitTest: Bool { processRole == .unitTests }

private let _terminationHandler = Mutex<(any TerminationHandler)?>(nil)
public var terminationHandler: (any TerminationHandler)? {
    get { _terminationHandler.withLock { $0 } }
    set { _terminationHandler.withLock { $0 = newValue } }
}

public protocol TerminationHandler: Sendable {
    @MainActor
    func beforeTermination()
}
