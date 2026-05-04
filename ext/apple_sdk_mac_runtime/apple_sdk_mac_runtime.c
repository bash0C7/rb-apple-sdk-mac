#include <ruby.h>
#include "AppleSDKMacRuntime-Swift.h"

static VALUE rb_apple_sdk_mac_runtime_perform(VALUE self, VALUE input) {
    const char *c_input = StringValueCStr(input);
    char *result = apple_sdk_mac_runtime_perform(c_input);
    if (result == NULL) {
        return rb_utf8_str_new_cstr("");
    }
    VALUE rb_result = rb_utf8_str_new_cstr(result);
    apple_sdk_mac_runtime_free(result);
    return rb_result;
}

void Init_apple_sdk_mac_runtime(void) {
    VALUE module = rb_define_module("AppleSdkMac");
    rb_define_singleton_method(module, "perform", rb_apple_sdk_mac_runtime_perform, 1);
}
