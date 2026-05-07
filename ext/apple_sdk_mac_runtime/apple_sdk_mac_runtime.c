#include <ruby.h>
#include <dlfcn.h>
#include "AppleSDKMacRuntime-Swift.h"

// proc_registry lives in the Swift runtime dylib (see appleProcRegistry in
// RuntimeBridge.swift). The previous rb_define_variable("$__apple_sdk_mac_proc_registry")
// approach didn't work under Ruby::Box: the Ruby-visible global was Box-wrapped
// and didn't share storage with the C-static VALUE the dispatcher read.
// runtime_proc_registry_get / runtime_proc_registry_init are exported from the
// libAppleSDKMacRuntime.dylib in flat namespace, so both this C ext and any
// glue dylib resolve to the same Hash regardless of RTLD_LOCAL boundaries.
#define proc_registry runtime_proc_registry_get()

static VALUE rb_dlopen_glue(VALUE self, VALUE path) {
    void *h = dlopen(StringValueCStr(path), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        rb_raise(rb_eRuntimeError, "dlopen failed: %s", dlerror());
    }
    return ULL2NUM((uint64_t)h);
}

static VALUE rb_dlsym_glue(VALUE self, VALUE handle, VALUE symname) {
    void *h = (void *)NUM2ULL(handle);
    void *fn = dlsym(h, StringValueCStr(symname));
    if (!fn) {
        rb_raise(rb_eRuntimeError, "dlsym failed: %s", dlerror());
    }
    return ULL2NUM((uint64_t)fn);
}

typedef VALUE (*glue_fn_t)(const VALUE *argv, int argc);

static VALUE rb_invoke_glue(VALUE self, VALUE fn_ptr_v, VALUE args_v) {
    Check_Type(args_v, T_ARRAY);
    glue_fn_t fn = (glue_fn_t)NUM2ULL(fn_ptr_v);
    return fn(RARRAY_CONST_PTR(args_v), (int)RARRAY_LEN(args_v));
}

static void ruby_callback_dispatcher(uint64_t proc_id, int64_t arg) {
    VALUE pid = ULL2NUM(proc_id);
    VALUE proc = rb_hash_lookup(proc_registry, pid);
    if (NIL_P(proc)) return;
    VALUE args[1] = { LL2NUM(arg) };
    rb_proc_call_with_block(proc, 1, args, Qnil);
}

// T53a — N-arg dispatcher path. Multi-arg typed escaping blocks (URLSession
// completion handler 等) は ThreadingBridge.enqueueFromAppleThread3 経由で
// (procId, count, args[]) 形で main thread queue に積まれ、 ここで Ruby Array
// 引数に展開して proc を invoke する。 1-arg path との backward compat 維持。
static void ruby_callback_dispatcher_n(uint64_t proc_id, int32_t count, const int64_t *args) {
    VALUE pid = ULL2NUM(proc_id);
    VALUE proc = rb_hash_lookup(proc_registry, pid);
    if (NIL_P(proc)) return;
    if (count < 0 || count > 8) return;
    VALUE rargs[8];
    for (int32_t i = 0; i < count; i++) rargs[i] = LL2NUM(args[i]);
    rb_proc_call_with_block(proc, count, rargs, Qnil);
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

static VALUE rb_async_taskgroup_double(VALUE self, VALUE a, VALUE b, VALUE c) {
    return LL2NUM(runtime_async_test_taskgroup_double(NUM2LL(a), NUM2LL(b), NUM2LL(c)));
}

// T54a — `runtime_rb_array_len` の wrapper は当初 C ext bundle 側に置いた
// (RARRAY_LEN macro 直呼出ができるため) が、 mkmf がコンパイルする C ext
// bundle は two-level namespace で linked されるため、 dlopen された glue
// dylib の flat-namespace lookup から見えない。 そのため Swift dylib 側に
// 移動した (RuntimeBridge.swift)。 そこから rb_funcallv("length") + rb_num2ll
// で同等の動作を実現している。

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

static VALUE rb_callback_pillar_register_midi_notify(VALUE self, VALUE proc) {
    VALUE pid = rb_obj_id(proc);
    rb_hash_aset(proc_registry, pid, proc);
    int32_t slot = runtime_callback_pillar_register_midi_notify(NUM2ULL(pid));
    if (slot < 0) {
        rb_raise(rb_eRuntimeError, "midiNotifyProc slot pool exhausted");
    }
    uint64_t fnptr = runtime_callback_pillar_get_midi_notify_fnptr(slot);
    return rb_ary_new_from_args(2, INT2FIX(slot), ULL2NUM(fnptr));
}

static VALUE rb_callback_pillar_unregister_midi_notify(VALUE self, VALUE slot) {
    runtime_callback_pillar_unregister_midi_notify(NUM2INT(slot));
    return Qnil;
}

// Phase 7 T2c — persistent (escaping) block slot table.
static VALUE rb_callback_pillar_register_block_persistent(VALUE self, VALUE proc) {
    VALUE pid = rb_obj_id(proc);
    rb_hash_aset(proc_registry, pid, proc);
    uint64_t slot_id = runtime_callback_register_block_persistent(NUM2ULL(pid));
    return ULL2NUM(slot_id);
}

static VALUE rb_callback_pillar_unregister_block_persistent(VALUE self, VALUE slot_id) {
    runtime_callback_unregister_block_persistent(NUM2ULL(slot_id));
    return Qnil;
}

static VALUE rb_callback_pillar_release_auto_block(VALUE self, VALUE slot_id) {
    runtime_callback_release_auto_block(NUM2ULL(slot_id));
    return Qnil;
}

// proc_registry lives in libAppleSDKMacRuntime.dylib (flat namespace). Both
// the dispatcher above (via the proc_registry macro = runtime_proc_registry_get())
// and per-symbol glue Swift dylibs reach the same Hash, sidestepping
// Ruby::Box's wrapping of rb_define_variable globals.

void Init_apple_sdk_mac_runtime(void) {
    runtime_proc_registry_init();
    runtime_callback_set_dispatcher(ruby_callback_dispatcher);
    runtime_callback_set_dispatcher_n(ruby_callback_dispatcher_n);
    VALUE module = rb_define_module("AppleSDKMacRuntime");
    rb_define_singleton_method(module, "dlopen_glue", rb_dlopen_glue, 1);
    rb_define_singleton_method(module, "dlsym_glue", rb_dlsym_glue, 2);
    rb_define_singleton_method(module, "invoke_glue", rb_invoke_glue, 2);
    rb_define_singleton_method(module, "ref_release", rb_ref_release, 1);
    rb_define_singleton_method(module, "arc_counter_bump", rb_arc_counter_bump, 1);
    rb_define_singleton_method(module, "threading_poll", rb_threading_poll, 1);
    rb_define_singleton_method(module, "runloop_pump", rb_runloop_pump, 1);
    rb_define_singleton_method(module, "conformance_register_handlers", rb_conformance_register, 1);
    rb_define_singleton_method(module, "conformance_release_handlers", rb_conformance_release, 1);

    VALUE test_module = rb_define_module_under(module, "Test");
    rb_define_singleton_method(test_module, "callback_register", rb_callback_register_test, 0);
    rb_define_singleton_method(test_module, "callback_invoke", rb_callback_invoke_test, 2);
    rb_define_singleton_method(test_module, "threading_enqueue_from_thread", rb_threading_enqueue, 2);
    rb_define_singleton_method(test_module, "ref_retain_object", rb_ref_retain_test, 1);
    rb_define_singleton_method(test_module, "ref_lookup_object_id", rb_ref_lookup_test, 1);
    rb_define_singleton_method(test_module, "marshal_string_round_trip", rb_marshal_string_rt, 1);
    rb_define_singleton_method(test_module, "marshal_int_round_trip", rb_marshal_int_rt, 1);
    rb_define_singleton_method(test_module, "marshal_array_to_swift_count", rb_marshal_array_count, 1);
    rb_define_singleton_method(test_module, "raise_runtime_error", rb_raise_runtime_error_test, 1);
    rb_define_singleton_method(test_module, "raise_argument_error", rb_raise_argument_error_test, 1);
    rb_define_singleton_method(test_module, "arc_release_counter_init", rb_arc_counter_init, 0);
    rb_define_singleton_method(test_module, "arc_release_counter_value", rb_arc_counter_value, 1);
    rb_define_singleton_method(test_module, "async_await_sleep_and_double", rb_async_await_sleep, 1);
    rb_define_singleton_method(test_module, "async_taskgroup_double", rb_async_taskgroup_double, 3);

    VALUE callback_pillar_module = rb_define_module_under(module, "CallbackPillar");
    rb_define_singleton_method(callback_pillar_module, "register_midi_notify", rb_callback_pillar_register_midi_notify, 1);
    rb_define_singleton_method(callback_pillar_module, "unregister_midi_notify", rb_callback_pillar_unregister_midi_notify, 1);
    rb_define_singleton_method(callback_pillar_module, "register_block_persistent", rb_callback_pillar_register_block_persistent, 1);
    rb_define_singleton_method(callback_pillar_module, "unregister_block_persistent", rb_callback_pillar_unregister_block_persistent, 1);
    rb_define_singleton_method(callback_pillar_module, "release_auto_block", rb_callback_pillar_release_auto_block, 1);
}
