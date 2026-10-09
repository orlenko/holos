import HolosCore

public func isInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

public func isUnavailable(_ error: HolosError?) -> Bool {
    if case .unavailable? = error { return true }
    return false
}
