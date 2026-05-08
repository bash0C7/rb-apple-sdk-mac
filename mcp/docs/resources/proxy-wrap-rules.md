# proxy 自動 wrap ルール (opaque_ref / cftype_ref)

`Apple.discover` の `:return_kind` が `:opaque_ref` または `:cftype_ref` のとき、 戻り値の raw Integer (= OpaquePointer) を自動的に proxy インスタンスに wrap して返します。 これで chain 呼び出しが自然に書けます。

## auto-wrap の条件

`NamespaceBuilder#opaque_ref_return?`:

```ruby
def opaque_ref_return?(sym)
  kind = sym[:return_kind]
  return false if kind.nil?
  return true if kind.is_a?(Symbol) && (kind == :opaque_ref || kind == :cftype_ref)
  return true if kind.is_a?(Hash) && (kind[:kind] == :opaque_ref || kind[:kind] == :cftype_ref)
  false
end
```

該当すると、 dispatcher の戻り値 (Integer) を `proxy_class.from_ref(raw)` で wrap した proxy インスタンスを返します。

## proxy インスタンスの正体

`Class.new` で動的に作られる空クラス。 1 個の状態を持ちます:

```ruby
attr_reader :__opaque_ref
```

これは Apple object の OpaquePointer を Integer 化したもの。 method 呼び出し時に `unwrap_proxy_args` で argv の先頭に prepend されて Apple SDK 側に渡ります。

## chain 呼び出し

```ruby
url = Apple::Foundation::URL.init_string("https://example.com/foo")
sub = url.appendingPathComponent("bar")  # ← url.__opaque_ref が argv[0] に prepend
sub2 = sub.appendingPathComponent("baz")
puts sub2.path  # /foo/bar/baz
```

`URL.appendingPathComponent` の戻り値も URL 型なので、 そのまま `.appendingPathComponent` をチェインできます。

## return_klass: で wrap 先を override

戻り値の型が receiver と違う場合に明示指定:

```ruby
Apple.discover(
  framework: :Foundation,
  klass: :NSURLSession,
  selector: :"dataTaskWithURL:",
  return_kind: :opaque_ref,
  return_klass: :NSURLSessionDataTask
)
session = ...
task = session.dataTaskWithURL(url)   # NSURLSessionDataTask proxy が返る
```

## Marshaller 側の挙動

glue dylib 内では:

```swift
// receiver の Integer → OpaquePointer → Apple class
let receiver = unsafeBitCast(
    OpaquePointer(bitPattern: rb_num2ull(argv[0])),
    to: NSURL.self
)

// 戻り値: OpaquePointer → Integer
return rb_ull2inum(UInt64(bitPattern: Int64(opaque_pointer)))
```

Ruby 側に戻った Integer を `from_ref(raw)` でラップして proxy 化、 という二段階です。

## opaque_ref と cftype_ref の違い

- `opaque_ref` — Swift class / ObjC class / OpaquePointer 系。 retain 管理は Ruby GC に任せる
- `cftype_ref` — Core Foundation 型 (CFString, CFArray 等)。 ARC pillar 経由で `runtime_arc_unbox_cftype` / `runtime_arc_box_cftype` でラップ。 自動的に `takeRetainedValue()` 等を発行

どちらも proxy wrap 先 class は同じ仕組みで決まります。

## chain 呼び出ししない値型

`:int` / `:bool` / `:string` / `:float` 戻り値は raw Ruby 値 (Integer / Boolean / String / Float) として返り、 proxy wrap は走りません。
