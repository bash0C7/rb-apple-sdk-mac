import Foundation

@c
public func apple_sdk_mac_runtime_perform(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    let s = String(cString: input)
    let result = apple_sdk_mac_runtime_perform(s)
    return strdup(result)!
}

@c
public func apple_sdk_mac_runtime_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
