# KB 分類オーバーライド (`:params` / `:return_kind`)

KB classifier は `.swiftinterface` パース時に各引数の `kind` を推論しますが、 たまに誤判定します。 そのときは `Apple.discover` の `:params` / `:return_kind` キーワードで明示的に上書きできます。

## よくある誤判定

| KB の判定 | 実際 | 救済 |
|---|---|---|
| `CFStringRef` を `string` (char* 同等扱い) | CFTypeRef として扱うべき | `kind: :cftype_ref` で override |
| buffer (mutable char*) を `is_out_param=true` | in-pointer | `kind: :string` 等で override |
| Boolean を unrecognised return | `bool` | `return_kind: :bool` |
| `void*` 単 pointer を out-pointer | refCon (in-pointer) | TemplateGenerator 側で自動補正 (T48) |

## kind sym → Swift 型 (KIND_SYM_TO_TYPE)

`lib/apple_sdk_mac/public_api.rb`:

```ruby
KIND_SYM_TO_TYPE = {
  string:           "const char *",
  int:              "Int64",
  bool:             "Bool",
  float:            "Double",
  opaque_ref:       "OpaquePointer",
  cftype_ref:       "CFTypeRef",
  void_ptr_nilable: "void *",
  block_persistent: "block_persistent_thunk"
}
```

## 使い方の例

### CFTypeRef 引数を明示

`CGImageSourceCreateWithURL` は CFURL + CFDictionary を取る。 KB が混乱したら override:

```ruby
Apple.discover(
  framework: :ImageIO,
  symbol: :CGImageSourceCreateWithURL,
  params: [
    { kind: :cftype_ref, type: "CFURL", nilable: false },
    { kind: :cftype_ref, type: "CFDictionary", nilable: true }
  ],
  return_kind: :opaque_ref
)
```

### nilable: false で force-unwrap

Swift bridge で T (non-Optional) 必須の API。 Marshaller が `arg!` を emit する。

```ruby
Apple.discover(
  framework: :Foundation,
  symbol: :CGImageSourceCreateWithURL,
  params: [
    { kind: :cftype_ref, type: "CFURL", nilable: false }   # force-unwrap
  ]
)
```

### return_kind で戻り値型を override

KB が unrecognised return として処理する API:

```ruby
Apple.discover(
  framework: :Foundation,
  symbol: :SomeBoolReturning,
  return_kind: :bool
)
```

### return_klass で proxy auto-wrap 先を指定

戻り値が receiver クラスと違う型の場合 (`NSURLSession#dataTask` が `NSURLSessionDataTask` を返す等):

```ruby
Apple.discover(
  framework: :Foundation,
  klass: :NSURLSession,
  selector: :"dataTaskWithURL:",
  return_kind: :opaque_ref,
  return_klass: :NSURLSessionDataTask
)
```

## 短縮形 (Symbol のみ)

各 entry が Hash でなく Symbol だけでも OK。 type は `KIND_SYM_TO_TYPE` から自動引き:

```ruby
Apple.discover(
  framework: :Foundation,
  symbol: :something,
  params: [:string, :int, :bool]   # 3 個の引数を kind sym で
)
```

## いつ override が必要か

- KB rebuild してない古いシンボル
- KB classifier がまだ対応してない新しい kind 組み合わせ
- 同名で異なるシグネチャの overload で KB が間違ったほうを掴んだとき

普段は KB の判定をそのまま使えば OK。 動かないときの脱出口です。
