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

static VALUE rb_marshal_string_rt(VALUE self, VALUE s) {
    const char *c = StringValueCStr(s);
    char *res = runtime_marshal_string_round_trip(c);
    VALUE rb = rb_utf8_str_new_cstr(res);
    runtime_string_free(res);
    return rb;
}

static VALUE rb_marshal_int_rt(VALUE self, VALUE v) {
    int64_t r = runtime_marshal_int_round_trip(NUM2LL(v));
    return LL2NUM(r);
}

static VALUE rb_marshal_array_count(VALUE self, VALUE ary) {
    Check_Type(ary, T_ARRAY);
    int64_t r = runtime_marshal_array_count((int64_t)RARRAY_LEN(ary));
    return LL2NUM(r);
}

static VALUE rb_raise_runtime_error_test(VALUE self, VALUE msg) {
    char *m = runtime_raise_request(0, StringValueCStr(msg));
    VALUE str = rb_utf8_str_new_cstr(m);
    runtime_string_free(m);
    rb_raise(rb_eRuntimeError, "%s", StringValueCStr(str));
    return Qnil;
}

static VALUE rb_raise_argument_error_test(VALUE self, VALUE msg) {
    char *m = runtime_raise_request(1, StringValueCStr(msg));
    VALUE str = rb_utf8_str_new_cstr(m);
    runtime_string_free(m);
    rb_raise(rb_eArgError, "%s", StringValueCStr(str));
    return Qnil;
}

void Init_apple_sdk_mac_runtime(void) {
    VALUE module = rb_define_module("AppleSDKMacRuntime");
    rb_define_singleton_method(module, "ref_retain_test_object", rb_ref_retain_test, 1);
    rb_define_singleton_method(module, "ref_lookup_test_object_id", rb_ref_lookup_test, 1);
    rb_define_singleton_method(module, "ref_release", rb_ref_release, 1);
    rb_define_singleton_method(module, "marshal_string_round_trip", rb_marshal_string_rt, 1);
    rb_define_singleton_method(module, "marshal_int_round_trip", rb_marshal_int_rt, 1);
    rb_define_singleton_method(module, "marshal_array_to_swift_count", rb_marshal_array_count, 1);
    rb_define_singleton_method(module, "raise_runtime_error_test", rb_raise_runtime_error_test, 1);
    rb_define_singleton_method(module, "raise_argument_error_test", rb_raise_argument_error_test, 1);
}
