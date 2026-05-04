#include <ruby.h>
#include "AppleSDKMacRuntime-Swift.h"

static VALUE rb_ref_retain_test(VALUE self, VALUE oid) {
    uint64_t id = NUM2ULL(oid);
    return UINT2NUM(runtime_ref_retain_test(id));
}

static VALUE rb_ref_lookup_test(VALUE self, VALUE handle) {
    uint32_t h = NUM2UINT(handle);
    return ULL2NUM(runtime_ref_lookup_test(h));
}

static VALUE rb_ref_release(VALUE self, VALUE handle) {
    runtime_ref_release(NUM2UINT(handle));
    return Qnil;
}

void Init_apple_sdk_mac_runtime(void) {
    VALUE module = rb_define_module("AppleSDKMacRuntime");
    rb_define_singleton_method(module, "ref_retain_test_object", rb_ref_retain_test, 1);
    rb_define_singleton_method(module, "ref_lookup_test_object_id", rb_ref_lookup_test, 1);
    rb_define_singleton_method(module, "ref_release", rb_ref_release, 1);
}
