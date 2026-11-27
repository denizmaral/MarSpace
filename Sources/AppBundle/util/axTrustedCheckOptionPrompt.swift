@preconcurrency @unsafe import ApplicationServices

let axTrustedCheckOptionPrompt: String = unsafe kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String // A constant: not owned
