# apple_sdk_mac-irb

IRB autocomplete, documentation preview, and discover prefetch for [rb-apple-sdk-mac](https://github.com/bash0C7/rb-apple-sdk-mac).

This is a sub-gem of the parent repository with its own gemspec and a `path:` dependency on the parent. It is not published to rubygems.org. It keeps `irb`, `reline`, and `repl_type_completor` out of the main gem's dependencies.

## What it does

- Reline completion for `Apple::<Framework>::<Klass>.<method>` chains from the local Knowledge Base
- The `:show_doc` dialog filled with Knowledge Base documentation on hover. Objective-C and C frameworks carry Apple's header documentation; Swift overlays carry none, because `*.swiftinterface` files have no `///` comments
- A documentation fallback through `foundation_model_mac` (Apple Intelligence on device) when that gem is installed and the Knowledge Base row has no documentation
- A background `Apple.discover` prefetch on hover, once per `(framework, klass, name)`

`install!` sets `IRB.conf[:COMPLETOR]` to `:type`. Apple-prefixed input goes to the Apple completion provider and other input goes to IRB's completor; when IRB falls back to `RegexpCompletor`, other input gets no candidates.

## Layout

```
irb/
├── apple_sdk_mac-irb.gemspec
├── Gemfile
├── sig/apple_sdk_mac_irb.rbs
├── lib/apple_sdk_mac/irb.rb              # Context / CandidateProvider / Completor / AutoDiscoverer / install!
├── lib/apple_sdk_mac/irb/doc_resolver.rb # Knowledge Base row → :show_doc payload
├── lib/apple_sdk_mac/irb/doc_dialog.rb   # Reline :show_doc proc chained with IRB's RDoc dialog
├── lib/apple_sdk_mac/irb/prefetcher.rb   # background discover, once per symbol
├── lib/apple_sdk_mac/irb/llm_resolver.rb # foundation_model_mac documentation fallback
└── test/
```

## Installation

The parent repository's bundle includes this sub-gem. In the repository root:

```bash
bundle install
bundle exec rake compile
bundle exec rake apple:knowledge:rebuild
```

## Run

From the repository root:

```
$ RUBY_BOX=1 bundle exec irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::<TAB>
> Apple::Foundation::U<TAB>
> Apple::Foundation::URL.<TAB>
```

`install!` does nothing when already installed and accepts `knowledge_cache:` and `discover_proc:` overrides. `uninstall!` clears the installed state but leaves the `prepend` on `IRB::Context` and `IRB::RelineInputMethod` in place; the prepended code is inactive until `install!` runs again.

## Environment variables

| Name | Effect |
|---|---|
| `APPLE_IRB_NO_LLM` | `1` disables the `foundation_model_mac` documentation fallback. |
| `APPLE_IRB_DEBUG` | `1` prints `foundation_model_mac` load failures and `:show_doc` RDoc fallback errors with `warn`. |

## Development

In `irb/`:

```bash
bundle install
bundle exec rake test
```

`rake test` validates `sig/apple_sdk_mac_irb.rbs`, then runs the tests with fake Knowledge Bases and stubbed Reline / IRB hooks, so no TTY is needed.

## License

MIT
