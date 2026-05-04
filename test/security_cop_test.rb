# frozen_string_literal: true
require "test_helper"

class TestSecurityCop < Test::Unit::TestCase
  def test_string_eval_methods_raise_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    inside_attempt = -> { box.send(:eval, "1 + 1") }
    assert_raise(SecurityError) { inside_attempt.call }

    outside_attempt = -> { Object.new.send(:eval, "1 + 1") }
    assert_equal 2, outside_attempt.call
  end

  def test_system_blocked_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    inside_attempt = -> { box.send(:system, "true") }
    assert_raise(SecurityError) { inside_attempt.call }
  end

  def test_file_read_blocked_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    inside_attempt = -> { box.send(:File).read("/etc/hosts") }
    assert_raise(SecurityError) { inside_attempt.call }
  end
end
