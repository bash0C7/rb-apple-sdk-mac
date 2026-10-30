# frozen_string_literal: true

module AppleSDKMac
  module IrbElicitation
    module_function

    def available?
      return false unless defined?(IRB)
      !IRB.CurrentContext.nil?
    rescue StandardError
      false
    end

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
