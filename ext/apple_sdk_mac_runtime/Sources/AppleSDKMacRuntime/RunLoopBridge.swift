import Foundation

/// Run loop pumping for callbacks delivered on the Ruby thread's run loop.
public enum RunLoopBridge {
    /// Runs the current run loop in the default mode for up to `timeoutSeconds`, returning after the first handled source.
    public static func pump(timeoutSeconds: Double) {
        CFRunLoopRunInMode(.defaultMode, timeoutSeconds, true)
    }
}
