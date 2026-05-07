# frozen_string_literal: true
# IRB autocomplete 実地試用 launcher。 必要な require を済ませた IRB セッションを
# 起動し、 試すべき入力を画面に表示する。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/irb_completion_try.rb
require "irb"
require "apple_sdk_mac"

puts <<~GUIDE

  ┌─────────────────────────────────────────────────────────────────┐
  │  Apple SDK autocomplete enabled — TAB を押すと候補が出るで       │
  └─────────────────────────────────────────────────────────────────┘

  ① framework 列挙
      Apple::<TAB>
      → ARKit, AVFAudio, AVFoundation, ... (100 frameworks)

  ② framework 内の type を prefix で絞る
      Apple::Foundation::U<TAB>
      → URL, URLComponents, URLError, URLQueryItem, URLRequest, ...

      Apple::Vision::Recogn<TAB>
      → RecognizeAnimalsRequest, RecognizeTextRequest, ...

      Apple::SwiftUI::St<TAB>
      → State, Stepper, ...

  ③ class の method を列挙
      Apple::Foundation::URL.<TAB>
      → appendingPathComponent, appendingPathExtension, fragment, ...

  ④ method 確定で auto-discover (* + spinner が回って Apple.discover が走る)
      Apple::Foundation::URL.appendingPathComponent<TAB>

  ⑤ exit で抜ける

GUIDE

IRB.start
