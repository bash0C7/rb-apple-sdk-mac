# frozen_string_literal: true

require_relative "security_cop/policy"

class Object
  string_eval_methods = %i[eval class_eval module_eval instance_eval]
  string_eval_methods.each do |m|
    next unless method_defined?(m) || private_method_defined?(m)
    original = instance_method(m)
    define_method(m) do |*args, **kwargs, &block|
      AppleSDKMac::SecurityCop.deny!("#{m}(String)") if args.first.is_a?(String)
      original.bind(self).call(*args, **kwargs, &block)
    end
  end

  %i[system spawn exec].each do |m|
    define_method(m) do |*|
      AppleSDKMac::SecurityCop.deny!(m.to_s)
    end
  end
end

module Kernel
  module_function

  def `(*)
    AppleSDKMac::SecurityCop.deny!("backtick subprocess")
  end
end

class File
  class << self
    %i[read open new readlines binread foreach].each do |m|
      define_method(m) do |*|
        AppleSDKMac::SecurityCop.deny!("File.#{m}")
      end
    end
  end
end
