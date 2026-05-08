# Apple.discover の 7 個の keyword shape

`Apple.discover(framework:, ...)` には 7 種類の keyword 組み合わせがあります。 KB の `kind` に対応してどの shape を選ぶか決まります。

## 早見表

| KB kind | keyword shape | 必須 keyword | 例 |
|---|---|---|---|
| `function` (abi=c) | C 関数 | `symbol:` | `Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)` |
| `objc_method_class` | ObjC クラスメソッド | `klass:` + `class_method:` | `Apple.discover(framework: :Foundation, klass: :NSString, class_method: :"stringWithUTF8String:")` |
| `objc_method_instance` | ObjC インスタンスメソッド | `klass:` + `selector:` | `Apple.discover(framework: :Foundation, klass: :NSData, selector: :"length")` |
| `swift_func` | Swift function | `swift_func:` (+ optional `klass:`) | `Apple.discover(framework: :Foundation, swift_func: :NSStringFromClass)` |
| `swift_init` | Swift initializer | `klass:` + `swift_initializer:` | `Apple.discover(framework: :Foundation, klass: :URL, swift_initializer: :"init(string:)")` |
| `swift_property` | Swift property | `klass:` + `swift_property:` (+ `instance:`) | `Apple.discover(framework: :Foundation, klass: :URL, swift_property: :path, instance: true)` |
| (any) | generic 解決 | + `type_args:` | `Apple.discover(framework: :Foundation, swift_func: :foo, type_args: [:String])` |

## 7 shape の詳細

### 1. `symbol:` — 純 C 関数

KB `kind=function`、 `abi=c` の symbol。 README 正規 3 行に出てくる canonical form。

```ruby
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

### 2. `class_method:` (+ `klass:`) — ObjC クラスメソッド

KB `kind=objc_method_class`。 selector の `:` は文字列内に保持される。

```ruby
Apple.discover(framework: :Foundation, klass: :NSString,
               class_method: :"stringWithUTF8String:")
str = Apple::Foundation::NSString.stringWithUTF8String("hello")
```

### 3. `selector:` (+ `klass:`) — ObjC インスタンスメソッド

KB `kind=objc_method_instance`。 receiver は proxy instance の `__opaque_ref` を経由。

```ruby
Apple.discover(framework: :Foundation, klass: :NSData, selector: :"length")
len = data.length
```

### 4. `swift_func:` — Swift function

KB `kind=swift_func`。 `klass:` を併用すると `Klass.func` static method 化、 単独だと top-level。

```ruby
Apple.discover(framework: :Foundation, swift_func: :NSStringFromClass)

# クラス所属 Swift func
Apple.discover(framework: :Foundation, klass: :URL,
               swift_func: :"appendingPathComponent(_:)")
```

### 5. `swift_initializer:` (+ `klass:`) — Swift initializer

KB `kind=swift_init`。

```ruby
Apple.discover(framework: :Foundation, klass: :URL,
               swift_initializer: :"init(string:)")
url = Apple::Foundation::URL.init_string("https://example.com")
```

### 6. `swift_property:` (+ `klass:`, `instance:`) — Swift property

KB `kind=swift_property`。 `instance: true` でインスタンスプロパティ、 false で static。

```ruby
Apple.discover(framework: :Foundation, klass: :URL,
               swift_property: :path, instance: true)
puts url.path
```

### 7. `type_args:` — generic 解決

`swift_func:` 等と組み合わせて使用。 generic 制約付き API で T を解決する。

```ruby
Apple.discover(framework: :Foundation, swift_func: :foo, type_args: [:String])
```

## オプション keyword

すべての shape で使える追加 keyword。

| keyword | 用途 |
|---|---|
| `params:` | KB 分類オーバーライド (`override-recipes` 参照) |
| `return_kind:` | 戻り値型オーバーライド |
| `return_klass:` | proxy auto-wrap 先クラス指定 |
| `async:` | Swift async wrapping |

## どれを選ぶかの判断手順

1. KB で symbol を `apple_sdk_mac_get_symbol_info` で引く
2. `kind` フィールドを見る
3. 上の早見表で対応 shape を選ぶ
4. canonical name (`name` フィールド) を keyword 値に渡す

迷ったら `apple_sdk_mac_suggest_discover_call(intent: "...")` が自動で正しい shape を組み立てる。
