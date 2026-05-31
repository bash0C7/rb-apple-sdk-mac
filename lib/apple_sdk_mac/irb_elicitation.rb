# frozen_string_literal: true

module AppleSDKMac
  module IrbElicitation
    module_function

    def available?
      return false unless defined?(IRB)
      # IRB.CurrentContext は対話 session が無いと raise せず nil を返すため、
      # 戻り値を消費して判定する。raise 依存だと irb が(直接 or transitive に)
      # require されているだけのプロセスで true となり、elicit が stdin.gets で
      # blocking する false-positive が起きる。
      !IRB.CurrentContext.nil?
    rescue StandardError
      # boolean 判定としての rescue (No Silent Exception Swallowing の例外):
      # 将来 IRB 内部が CurrentContext で raise する場合の防御的な bool 畳み込み。
      # 握り潰しではなく「利用可否を bool に畳む」判定。
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
