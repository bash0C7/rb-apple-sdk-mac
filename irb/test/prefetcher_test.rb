# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/prefetcher"

# Prefetcher fires Apple.discover in a background Thread on popup
# hover so glue compilation is finished by the time the user actually
# invokes the method. Idempotent per (framework, klass, name).
class TestPrefetcher < Test::Unit::TestCase
  Prefetcher = AppleSDKMac::IRB::Prefetcher

  def make_discoverer(&block)
    d = Object.new
    d.define_singleton_method(:run, &block)
    d
  end

  def test_fires_for_apple_class_method_candidate
    fired = []
    d = make_discoverer { |ctx, name| fired << [ctx.framework, ctx.klass, name] }
    Prefetcher.new(discoverer: d).prefetch("Apple::Foundation::URL.appendingPathComponent").join
    assert_equal [["Foundation", "URL", "appendingPathComponent"]], fired
  end

  def test_does_not_fire_for_non_apple
    fired = false
    d = make_discoverer { |_ctx, _n| fired = true }
    t = Prefetcher.new(discoverer: d).prefetch("String.length")
    assert_nil t
    refute fired
  end

  def test_does_not_fire_for_module_or_apple_root
    fired = false
    d = make_discoverer { |_ctx, _n| fired = true }
    pf = Prefetcher.new(discoverer: d)
    assert_nil pf.prefetch("Apple::Foundation::URL")
    assert_nil pf.prefetch("Apple::Foundation")
    refute fired
  end

  def test_idempotent_for_same_key
    counter = 0
    d = make_discoverer { |_ctx, _n| counter += 1 }
    pf = Prefetcher.new(discoverer: d)
    t1 = pf.prefetch("Apple::Foundation::URL.appendingPathComponent")
    t1.join if t1
    t2 = pf.prefetch("Apple::Foundation::URL.appendingPathComponent")
    assert_nil t2
    assert_equal 1, counter
  end

  def test_swallows_discoverer_exceptions
    d = make_discoverer { |_ctx, _n| raise "boom" }
    pf = Prefetcher.new(discoverer: d)
    assert_nothing_raised do
      t = pf.prefetch("Apple::Foundation::URL.appendingPathComponent")
      t.join
    end
  end

  def test_started_query
    counter = 0
    d = make_discoverer { |_ctx, _n| counter += 1 }
    pf = Prefetcher.new(discoverer: d)
    refute pf.started?(framework: "Foundation", klass: "URL", name: "appendingPathComponent")
    pf.prefetch("Apple::Foundation::URL.appendingPathComponent").join
    assert pf.started?(framework: "Foundation", klass: "URL", name: "appendingPathComponent")
  end
end
