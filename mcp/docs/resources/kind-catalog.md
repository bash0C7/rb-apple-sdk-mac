# KB `kind` カタログと生成される Ruby メソッド形

KB の `symbols.kind` フィールドが、 NamespaceBuilder が定義する Ruby メソッドの形を決めます。

## 全 `kind` 一覧

| kind | 生成 Ruby 形 | 例 | 親 (parent_id) |
|---|---|---|---|
| `function` | `Apple::FW.foo(...)` (top-level method) | `Apple::CoreMIDI.MIDIClientCreate(...)` | なし |
| `global_constant` | `Apple::FW.foo` (top-level method として参照) | `Apple::Foundation.NSDateFormatterFullStyle` | なし |
| `swift_func` | `Apple::FW.foo` または `Apple::FW::Klass.foo` | `Apple::Foundation.NSStringFromClass(...)` | なし or クラス |
| `objc_method_class` | `Apple::FW::Klass.foo(...)` (singleton method) | `Apple::Foundation::NSString.stringWithUTF8String("x")` | クラス |
| `objc_method_instance` | `Apple::FW::Klass#foo(...)` (instance method) | `data.length` | クラス |
| `swift_init` | `Apple::FW::Klass.init_xxx(...)` | `Apple::Foundation::URL.init_string("...")` | クラス |
| `swift_property` | `proxy.foo` (getter) または class-level | `url.path` | クラス |
| `class` | `Apple::FW::Klass` (proxy 定数) | `Apple::Foundation::URLSession` | なし |
| `struct` | `Apple::FW::Klass` (proxy 定数) | `Apple::Foundation::URL` | なし |
| `actor` | `Apple::FW::Klass` (proxy 定数) | (Swift 6 actor) | なし |
| `protocol` | `Apple::FW::Klass` (proxy 定数) | `Apple::Foundation::Sendable` | なし |
| `enum_module` | `Apple::FW::Klass` (proxy 定数) | enum 名前空間 | なし |
| `enum_case` | (列挙のみ、 method 化はしない) | `URL.atURL` | enum |
| `instance_method` | (Swift method、 swift_func 同等扱い) | `func appendingPathComponent(...)` | クラス |
| `class_method` | (Swift static、 swift_func 同等扱い) | `static func from(...)` | クラス |
| `instance_property` | (Swift property、 swift_property と同等) | `var path: String` | クラス |

## NamespaceBuilder の振り分けロジック

`KIND_TO_DEFINER` (`lib/apple_sdk_mac/namespace_builder.rb`):

```ruby
KIND_TO_DEFINER = {
  "function"             => :method,            # top-level
  "global_constant"      => :method,            # top-level
  "swift_func"           => :method,            # top-level (or under_klass)
  "objc_method_class"    => :method_under_klass,
  "objc_method_instance" => :method_under_klass,
  "swift_init"           => :method_under_klass,
  "swift_property"       => :method_under_klass,
  "class"                => :constant,
  "struct"               => :constant,
  "actor"                => :constant,
  "protocol"             => :constant,
  "enum_module"          => :constant
}
```

3 mode に分類:
- `:method` — top-level on framework module
- `:method_under_klass` — proxy class の singleton/instance method
- `:constant` — proxy class as constant on framework module

## proxy class とは

`class` / `struct` / `actor` / `protocol` / `enum_module` が定義された framework に対して、 NamespaceBuilder が `Class.new` で動的に作る空クラス。 以下を持ちます:

```ruby
attr_reader :__opaque_ref
define_method(:initialize) { |raw_ref| @__opaque_ref = raw_ref }
define_singleton_method(:from_ref) { |raw_ref| new(raw_ref) }
```

`__opaque_ref` は Apple object の OpaquePointer を Integer 化したもの。 `from_ref(raw)` で wrap するクラスヘルパー。

## kind 別の特殊ケース

- `objc_method_instance` で `init` 始まりの selector → class singleton method として install (`alloc.init` 経路と揃えるため)
- `swift_property` で `instance: true` → proxy instance method、 `false` → class singleton method
- `enum_case` は method 化されず、 enum 名前空間の constant として参照
