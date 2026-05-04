import Foundation

public enum ErrorBridge {
    public enum Kind: Int32 {
        case runtimeError = 0
        case argumentError = 1
        case typeError = 2
    }
}
