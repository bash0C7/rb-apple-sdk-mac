#include <ruby.h>
#include "AppleSDKMacRuntime-Swift.h"

static VALUE proc_registry = Qnil;

static void ruby_callback_dispatcher(uint64_t proc_id, int64_t arg) {
    VALUE pid = ULL2NUM(proc_id);
    VALUE proc = rb_hash_lookup(proc_registry, pid);
    if (NIL_P(proc)) return;
    VALUE args[1] = { LL2NUM(arg) };
    rb_proc_call_with_block(proc, 1, args, Qnil);
}

static VALUE rb_callback_register_test(VALUE self) {
    VALUE block = rb_block_proc();
    VALUE pid = ULL2NUM((uint64_t)NUM2ULL(rb_obj_id(block)));
    rb_hash_aset(proc_registry, pid, block);
    return pid;
}

static VALUE rb_callback_invoke_test(VALUE self, VALUE pid, VALUE arg) {
    runtime_callback_invoke(NUM2ULL(pid), NUM2LL(arg));
    return Qnil;
}

static VALUE rb_threading_enqueue(VALUE self, VALUE pid, VALUE arg) {
    runtime_threading_enqueue(NUM2ULL(pid), NUM2LL(arg));
    return Qnil;
}

static VALUE rb_threading_poll(VALUE self, VALUE timeout) {
    int64_t n = runtime_threading_poll(NUM2DBL(timeout));
    return LL2NUM(n);
}

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

static VALUE rb_arc_counter_init(VALUE self) {
    return UINT2NUM(runtime_arc_counter_init());
}
static VALUE rb_arc_counter_bump(VALUE self, VALUE h) {
    runtime_arc_counter_bump(NUM2UINT(h));
    return Qnil;
}
static VALUE rb_arc_counter_value(VALUE self, VALUE h) {
    return LL2NUM(runtime_arc_counter_value(NUM2UINT(h)));
}

static VALUE rb_async_await_sleep(VALUE self, VALUE millis) {
    return LL2NUM(runtime_async_test_sleep_and_double(NUM2LL(millis)));
}

static VALUE rb_runloop_pump(VALUE self, VALUE timeout) {
    runtime_runloop_pump(NUM2DBL(timeout));
    return Qnil;
}

static VALUE rb_conformance_register(VALUE self, VALUE handlers) {
    Check_Type(handlers, T_HASH);
    uint64_t table_id = (uint64_t)rb_obj_id(handlers);
    rb_hash_aset(proc_registry, ULL2NUM(table_id), handlers);
    return UINT2NUM(runtime_conformance_register(table_id));
}

static VALUE rb_conformance_release(VALUE self, VALUE handle) {
    runtime_conformance_release(NUM2UINT(handle));
    return Qnil;
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
    proc_registry = rb_hash_new();
    rb_global_variable(&proc_registry);
    runtime_callback_set_dispatcher(ruby_callback_dispatcher);
    VALUE module = rb_define_module("AppleSDKMacRuntime");
    rb_define_singleton_method(module, "callback_register_test", rb_callback_register_test, 0);
    rb_define_singleton_method(module, "callback_invoke_test", rb_callback_invoke_test, 2);
    rb_define_singleton_method(module, "threading_enqueue_from_thread", rb_threading_enqueue, 2);
    rb_define_singleton_method(module, "threading_poll", rb_threading_poll, 1);
    rb_define_singleton_method(module, "ref_retain_test_object", rb_ref_retain_test, 1);
    rb_define_singleton_method(module, "ref_lookup_test_object_id", rb_ref_lookup_test, 1);
    rb_define_singleton_method(module, "ref_release", rb_ref_release, 1);
    rb_define_singleton_method(module, "marshal_string_round_trip", rb_marshal_string_rt, 1);
    rb_define_singleton_method(module, "marshal_int_round_trip", rb_marshal_int_rt, 1);
    rb_define_singleton_method(module, "marshal_array_to_swift_count", rb_marshal_array_count, 1);
    rb_define_singleton_method(module, "raise_runtime_error_test", rb_raise_runtime_error_test, 1);
    rb_define_singleton_method(module, "raise_argument_error_test", rb_raise_argument_error_test, 1);
    rb_define_singleton_method(module, "arc_release_counter_init", rb_arc_counter_init, 0);
    rb_define_singleton_method(module, "arc_counter_bump", rb_arc_counter_bump, 1);
    rb_define_singleton_method(module, "arc_release_counter_value", rb_arc_counter_value, 1);
    rb_define_singleton_method(module, "async_await_test_sleep_and_double", rb_async_await_sleep, 1);
    rb_define_singleton_method(module, "runloop_pump", rb_runloop_pump, 1);
    rb_define_singleton_method(module, "conformance_register_handlers", rb_conformance_register, 1);
    rb_define_singleton_method(module, "conformance_release_handlers", rb_conformance_release, 1);
}
