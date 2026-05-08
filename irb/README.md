# apple_sdk_mac-irb

IRB autocomplete + doc preview + auto-discover prefetch for [rb-apple-sdk-mac](https://github.com/bash0C7/rb-apple-sdk-mac).

Logical sub-gem inside the parent repo: same source tree, separate `gemspec`, `path:` dependency to the parent. Never published independently to rubygems.org — the IRB layer is a development/dogfooding companion to the main gem, kept out of the runtime require path so non-IRB users do not pull in `irb` / `reline` / `repl_type_completor` / `foundation_model_mac` / `translation_mac-locale`.

## What it does

The parent gem exposes Apple's macOS SDK to Ruby via dynamic Swift glue (`Apple.discover(...)` → per-symbol dylib build → method dispatch). To use it interactively you have to *know* which framework + class + method to discover. This sub-gem hands those names to you in IRB:

- **Reline autocomplete** for `Apple::<Framework>::<Klass>.<method>` chains, sourced from the local SDK Knowledge Base (295+ frameworks)
- **`:show_doc` dialog** filled with KB-sourced documentation on hover (ObjC / C frameworks ship with rich Apple-official doc strings; Swift overlays are bimodal — `///` is stripped from `*.swiftinterface` by the compiler)
- **LLM doc fallback** through `foundation_model_mac` (Apple Intelligence on-device) when the KB row has no documentation text
- **On-the-fly translation** of doc text through `translation_mac-locale` when `APPLE_SDK_DOC_LANG` / `LANG` resolve to a non-English BCP-47 tag
- **Background `Apple.discover` prefetch** triggered by the same hover, so the glue dylib is already compiled by the time the user actually invokes the method
- **Synchronous discover-on-confirm** when the user accepts a class-method completion via Reline's perfect-match path, with a Claude Code-style `* / +` spinner on stderr

Apple-prefixed completion delegates to a dedicated provider; non-Apple input is forwarded to IRB's standard `TypeCompletor` (AST/RBS, no constant enumeration — `RegexpCompletor` SEGVs under Ruby 4 + RUBY_BOX framework boxes, so it is explicitly avoided).

## Layout

```
irb/                                            # this sub-gem
├── apple_sdk_mac-irb.gemspec                   # path-deps: rb-apple-sdk-mac, rb-foundation-model-mac, translation_mac-locale, irb, reline, repl_type_completor, sqlite3
├── Gemfile                                     # path overrides matching mcp/ sub-gem convention
├── lib/apple_sdk_mac/irb.rb                    # entry: Context / CandidateProvider / Completor / Spinner / AutoDiscoverer / install!
├── lib/apple_sdk_mac/irb/doc_resolver.rb       # KB row → :show_doc payload + doc_transform hook
├── lib/apple_sdk_mac/irb/doc_dialog.rb         # Reline :show_doc proc, chained with IRB's RDoc fallback
├── lib/apple_sdk_mac/irb/prefetcher.rb         # idempotent per-(framework,klass,name) background discover
├── lib/apple_sdk_mac/irb/llm_resolver.rb       # foundation_model_mac wrapper for missing-doc fallback
└── test/                                       # 85 tests via test-unit
```

## Install

The sub-gem expects the parent repo cloned at `..`, plus sibling repos `rb-foundation-model-mac`, `rb-apple-sdk-knowledge`, and `rb-translation-mac` at `../../`. Inside `irb/`:

```bash
bundle install
```

This resolves the `path:` deps via `Gemfile`. The parent gem's KB must already be built; if not:

```bash
cd ..
bundle exec rake apple:knowledge:rebuild
```

## Run

```bash
$ irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::<TAB>
  → ARKit, AVFAudio, AVFoundation, AVKit, AVRouting, ... (100 frameworks)
> Apple::Foundation::U<TAB>
  → URL, URLComponents, URLError, URLQueryItem, URLRequest, ... (8 types)
> Apple::Foundation::URL.<TAB>
  → appendingPathComponent, appendingPathExtension, fragment, ... (15 methods)
```

`install!` is idempotent and accepts `knowledge_cache:`, `discover_proc:`, `spinner_io:` overrides for testing. `uninstall!` clears module-level state but does not undo the `prepend` on `IRB::Context` / `IRB::RelineInputMethod` — re-running `install!` simply re-arms it.

## Doc preview, prefetch, and translation

Hovering an Apple SDK candidate fills the right-side `:show_doc` dialog with documentation sourced from the KB (clang FullComment AST ingested by `rb-apple-sdk-knowledge`). The chained dialog proc tries the Apple resolver first, then falls back to IRB's RDoc-driven `:show_doc`; failures in the RDoc path are swallowed so a broken `~/.ri` store does not leak into the prompt.

While the popup renders, the same hover triggers a **background prefetch**: the symbol's `Apple.discover` runs in a separate Thread so the first real call has its glue dylib already compiled. Idempotent per `(framework, klass, name)`.

When `APPLE_SDK_DOC_LANG` is set to a non-English BCP-47 tag (e.g. `ja-JP`, `fr-FR`) and `translation_mac-locale` is available, doc text is translated by Apple Intelligence on the fly via a `doc_transform` lambda. `LANG` is consulted as fallback and POSIX-style values like `ja_JP.UTF-8` are accepted there too. English / `C` / `POSIX` / unset locales pass through unchanged. Per-input cache keeps the popup snappy across re-hovers.

```
$ APPLE_SDK_DOC_LANG=ja-JP irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::CoreFoundation::CFArrayAppendValue<TAB-hover>
  ┌─ candidates ─┐ ┌─ doc (ja-JP) ─────────────────────────┐
  │ ...          │ │ 配列に値を追加し、新しい最大インデック   │
  │              │ │ スを付与します。 値を追加する配列。      │
  └──────────────┘ └────────────────────────────────────────┘
```

## Environment variables

| Name | Effect |
|---|---|
| `APPLE_SDK_DOC_LANG` | BCP-47 target locale for doc translation (primary input). Unset / `en*` → identity transform. |
| `LANG` | POSIX-style fallback when `APPLE_SDK_DOC_LANG` is unset. `C` / `POSIX` → identity. |
| `APPLE_IRB_NO_LLM` | `=1` opts out of the `foundation_model_mac` doc fallback even when the gem is installed. |
| `APPLE_IRB_DEBUG` | `=1` surfaces optional-dep load failures (`translation_mac/locale`, `foundation_model_mac`) and `:show_doc` RDoc fallback errors via `warn`. |

## Tests

```bash
bundle exec rake test
```

85 tests via `test-unit`. The suite uses fake `Struct`-based knowledge caches and stubs Reline / IRB hooks so it runs in plain MRI without a TTY.

## Design references

- Spec: [`docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`](../docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md) — sub-gem split, completor wiring, doc resolver pipeline, prefetch idempotency, translation hook
- Parent gem: [`../README.md`](../README.md) — `Apple.discover` shapes, KB ingest, dispatch flow
- Sibling sub-gem: [`../mcp/README.md`](../mcp/README.md) — same logical-sub-gem pattern (separate gemspec, path-dep, never independently published)

## License

MIT, same as the parent gem.
