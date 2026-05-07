# Handoff — T52 + T53 完成、 T54 部分着手

Date: 2026-05-07 (T52 GREEN ~ T54 fixture commit まで)
Spec: `docs/superpowers/specs/2026-05-07-T51-T54-forecast-backcast.md`
Prev handoff: `docs/HANDOFF-2026-05-07-T52i.md`

## このセッションで完了した release 品質マイルストーン

### T52 GREEN
`examples/async_taskgroup.rb` が Apple Foundation NSOperationQueue +
NSBlockOperation で 3 個の block を **真の並列実行**。 results=[20,40,60]、
elapsed_ms=68、 parallel=true。 Ruby Thread fake / runtime fixture 退路ゼロ。
warmup phase で discover dlopen overhead を timing path から外し、 spec § 4
acceptance 全項目 PASS (smoke 8 assert)。

### T53 GREEN
`examples/urlsession_download.rb` が NSURLSession で実 HTTP download、 受信
NSData の length と sha256 を Ruby 側で計算して fixture と完全一致確認。
file:// 退路 / DEFERRED 退路ゼロ。 spec § 5 acceptance:
- scheme=http
- bytes=230 (T53_FIXTURE_BODY bytesize 完全一致)
- sha256=94d6...ed27877 (Digest::SHA256.hexdigest 完全一致)
- WEBrick fixture (stdlib TCPServer) で外部 network 依存ゼロ
- smoke 6 assert PASS

### 追加した release 品質機構 (T53 系延長 task、 各 RED + GREEN 独立 commit)

| # | Task | 内容 |
|---|---|---|
| T53a | `:block_persistent` Hash 形 (arity, types) で multi-arg typed dispatch | URLSession completion (Data?, URLResponse?, Error?) -> Void を Ruby に届ける runtime_threading_enqueue_3 経路。 ThreadingBridge / CallbackBridge / Ruby C ext 拡張、 CACHE_SCHEMA 1.4 bump |
| T53b | swift_call_for_class_method regex を `[A-Za-z]` 始まり許容に拡張 | NSURL.URLWithString → URL(string:) init bridge (大文字 acronym verb 対応) |
| T53c | objc_in_load `:string` を Swift String 化 + cstr 補助名併記 | URL(string: <String>) を成立させる、 stringWithUTF8String は cstr 補助名で維持 |
| T53d | emit_swift_property に NS-prefix strip 適用 | NSURLSession.shared → URLSession.shared |
| T53e | GATE 4 banned API check が NS-prefixed 明示 discover を bypass | NSURLSession discover で URLSession 含む glue を許可、 LLM 任意経路は引き続き ban |
| T53f | NS_STRIP_PRESERVE_LIST に value-type 系を登録 | NSData/NSString/NSArray/NSDict/NSSet は API divergent のため ObjC class form 維持 |
| T53g | zero-arg + non-void return を ObjC property bridge form 化 | NSData.length / NSArray.count 等 (parens なし property access) |
| T53h | `:raw_ptr` return kind 追加 | NSData.bytes 等 const void* 戻り値の raw bit pattern を Ruby Integer に |
| T53i | `:opaque_ref` Hash 形 value-type を NS-class 経由 bridge | URL/Data/String 等 struct への直接 unsafeBitCast による SIGTRAP 回避、 `unsafeBitCast(ptr, to: NSURL.self) as URL` 形 |
| T53j | `return_klass:` opt で proxy auto-wrap class を override | NSURLSession#dataTask が NSURLSessionDataTask の proxy instance を返す |
| (chore) | Rakefile sync_header に release config 明示 glob | swift build -c release の header が ext/ にコピーされるよう修正 |
| (chore) | apple:cache:clear_db で glue.sqlite を削除 | 実際の DB ファイル名 (CompiledGlueCache 用) に合わせ pattern 修正 |
| (T54 prereq) | CFTypeRef param に nilable: false opt + signature nil guard | Vision/CGImage 系の Swift bridged non-Optional T 受け入れ準備 |

### 追加した T54 fixture
- `examples/fixtures/ocr_hello.png` — 800×200 px 白背景/黒文字 96pt Helvetica Bold
- `script/regen_t54_fixture.swift` — swiftc -framework Cocoa で再生成 Swift CLI
- `script/regen_t54_fixture.rb` — Ruby wrapper

Vision OCR 検証済: confidence 1.0 で "HELLO RUBY" 認識。

## 残り blocker (T54 GREEN 完成のため)

T54 example は Vision/CoreGraphics 系の複雑な discover path を要求する。
spec § 6.2 の罠表 + 上記の T53 系延長機構を踏まえても、 さらに複数の
extension が必要:

### T54k (確実発火): objc_in_load `:cftype_ref` Hash 形 typed cast
現実装の `:cftype_ref` 形は OpaquePointer に bitPattern で復元するだけで、
具体 Swift CFType (CGImage 等) への unsafeBitCast cast を emit しない。
`VNImageRequestHandler.init(cgImage: CGImage, options: ...)` のように Swift
bridged 型を expect する path で type mismatch error。

- 期待 emit: `let arg0 = unsafeBitCast(OpaquePointer(...), to: CGImage.self)`
- nilable 対応: nil → 関連 init bridge は failable で対応

### T54l (確実発火): VNImageRequestHandler.init の `[VNImageOption: Any]?` 引数
options 引数は Swift native Dict 型で、 raw pointer から復元できない。
options が nil 想定の Apple.discover で、 template が直接 `nil` を渡す
特殊経路が必要 (もしくは options を完全に nil 固定の form に省略)。

- 暫定回避: 全 options 引数を nil 固定 (Hash 形 `{kind: :nilable_dict_literal}` 等の new kind)

### T54m (確実発火): performRequests:error: の error out param
Swift bridge は throws form (`try handler.perform([request])`) だが、 selector
"performRequests:error:" を直接 emit すると out NSError ** が処理できない。
template 側で try/catch ブロックに変換するか、 error_out kind を実装する必要。

### T54n (確実発火): Swift array property `request.results`
swift_property emit は `klass.prop` だが、 `[VNRecognizedTextObservation]?` のような
typed Swift array を Ruby Array<Integer> に marshal する return kind が無い。
新規 `:array_of_opaque_ref` return kind が必要 (params 側は T54a で実装済)。

### T54o (確実発火): VNRecognizedTextObservation.topCandidates(_:) → [VNRecognizedText]
Swift array 戻り値、 上記 T54n と類似の return marshal 必要。 加えて
single-segment selector の Int arg を int_typed Hash で渡せる必要。

### T54p (確実発火): VNRecognizedText.string property
`:string` return kind が objc_return_lines / swift_init_return_lines に未定義。
Swift String? → Ruby String VALUE 経路を追加。

### T54 GREEN
上記 T54k-T54p 完成後に example を組み立てる。

## 次の section: T55-T58
- T55: examples_smoke_test 全例 refute_match(/DEFERRED/) — T52/T53 で組込済、 T54 完成と同時に通る
- T56: LLM prompt 簡素化 — template-only path で v1.0 が成立する前提
- T57: rake test:release_quality 全 PASS aggregate
- T58: v1.0.0 promote

## 影響範囲 (本セッションで触ったコード)

新規 / 大幅改修:
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (T53b/T53c/T53d/T53f/T53g/T53h/T53i/T53a HEADER + nil guard)
- `lib/apple_sdk_mac/glue_compiler/marshallers.rb` (T53a CFTypeRefMarshaller nilable opt)
- `lib/apple_sdk_mac/glue_compiler/validation_gates.rb` (T53e BANNED bypass)
- `lib/apple_sdk_mac/namespace_builder.rb` (T53j wrap_class_for + return_klass)
- `lib/apple_sdk_mac/public_api.rb` (T53j return_klass + nilable opt pass-through)
- `lib/apple_sdk_mac/compiled_glue_cache.rb` (CACHE_SCHEMA 1.3 → 1.4)
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift` (T53a runtime_threading_enqueue_3 + set_dispatcher_n)
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/ThreadingBridge.swift` (T53a Pending struct + 3-arg path)
- `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackBridge.swift` (T53a rubyDispatcherN)
- `ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c` (T53a ruby_callback_dispatcher_n)
- `Rakefile` (sync_header release glob + clear_db pattern fix)
- `examples/async_taskgroup.rb` (T52 GREEN — warmup + plural addOperations)
- `examples/urlsession_download.rb` (T53 GREEN — 全置換)
- `examples/fixtures/ocr_hello.png` (T54 fixture)
- `script/regen_t54_fixture.{swift,rb}` (T54 fixture regen)
- `test/glue_compiler/template_generator_test.rb` (T53a/b/c/d/e/f/g/h/i RED tests)
- `test/namespace_builder_test.rb` (T53j RED test)
- `test/validation_gates_test.rb` (T53e RED test)
- `test/integration/examples_smoke_test.rb` (T53 + T54 RED smoke)

## 環境メモ
- CACHE_SCHEMA_VERSION: "1.3" → "1.4" (T53a で bump)
- runtime dylib: `runtime_threading_enqueue_3` / `runtime_callback_set_dispatcher_n` 追加 export
- Rakefile: `apple:runtime:sync_header` が release config の Swift.h を選ぶよう修正済
- Rakefile: `apple:cache:clear_db` が `glue.sqlite` を削除するよう修正済

## 再開手順
1. 本 handoff (`docs/HANDOFF-2026-05-07-T53-complete.md`) を read
2. spec (`docs/superpowers/specs/2026-05-07-T51-T54-forecast-backcast.md`) を read
3. 上記「T54 GREEN 残り blocker」 を順に解消 (T54k → T54l → ... → T54p)
4. T54 GREEN: `examples/vision_ocr.rb` を組み立て、 smoke 全 4 assert PASS
5. T55-T58 を spec § 8 順序で消化
