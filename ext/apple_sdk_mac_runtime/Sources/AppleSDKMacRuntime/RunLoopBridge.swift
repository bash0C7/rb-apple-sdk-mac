import Foundation
import CoreFoundation

public enum RunLoopBridge {
    public static func pump(timeoutSeconds: Double) {
        CFRunLoopRunInMode(.defaultMode, timeoutSeconds, true)
    }
}
