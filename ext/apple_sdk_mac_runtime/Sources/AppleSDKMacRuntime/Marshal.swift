import Foundation

/// String conversion between C and Swift.
public enum Marshal {
    /// Returns a Swift copy of the NUL-terminated UTF-8 string `c`.
    public static func swiftString(fromCString c: UnsafePointer<CChar>) -> String {
        String(cString: c)
    }

    /// Returns a `strdup` copy of `s` owned by the caller.
    public static func cString(fromSwift s: String) -> UnsafeMutablePointer<CChar> {
        strdup(s)!
    }
}
