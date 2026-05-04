import Foundation

public enum Marshal {
    public static func swiftString(fromCString c: UnsafePointer<CChar>) -> String {
        String(cString: c)
    }

    public static func cString(fromSwift s: String) -> UnsafeMutablePointer<CChar> {
        strdup(s)!
    }
}
