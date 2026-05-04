# frozen_string_literal: true
#
# WARNING: This file applies global monkey patches to Object, Kernel, File.
# It is intended to be loaded ONLY via Ruby::Box.require so that the patches
# stay scoped to the Apple box. Requiring this file from outside a Ruby::Box
# context will break the host process (test-unit, irb, etc. all rely on the
# patched methods).
#
# Trusted internal callers wrap restricted operations in
# AppleSDKMac::SecurityCop.allow { ... } to bypass the cop.

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
