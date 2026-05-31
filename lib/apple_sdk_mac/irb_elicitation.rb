# frozen_string_literal: true

module AppleSDKMac
  module IrbElicitation
    module_function

    def available?
      return false unless defined?(IRB)
      IRB.CurrentContext
      true
    rescue StandardError
      # boolean 判定としての rescue (No Silent Exception Swallowing の例外):
      # IRB 周辺で例外が起きる = 対話 session が利用不可、を意味する明示的な
      # false 返却。握り潰しではなく「利用可否を bool に畳む」判定。
      false
    end

    # framework::symbol_name が解決不能時にユーザへ context を問い合わせる。
    # 非対話 or 空 Enter → nil(呼び出し側は loud fail に縮退)。
    # stdin:/stdout: は依存注入(テスト用)。
    def elicit(framework:, symbol_name:, stdin: $stdin, stdout: $stdout)
      return nil unless available?
      stdout.print "#{framework}::#{symbol_name} could not be bridged automatically.\n" \
                   "Enter usage hint or type context (or press Enter to skip): "
      stdout.flush
      input = stdin.gets.to_s.chomp
      input.empty? ? nil : input
    end
  end
end
