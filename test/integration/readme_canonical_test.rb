# frozen_string_literal: true
require "test_helper"
require "open3"
require "tmpdir"

# Phase 7 / v1.0 — README L26-34 canonical snippet must run verbatim and
# produce a non-zero MIDIClientRef. This is THE acceptance gate: as long
# as this test is green, the central README claim holds.
#
# We run the snippet as a subprocess so the load path / RUBY_BOX init /
# Apple bootstrap are exercised exactly the way a user invokes from the
# command line — no test-helper shortcuts.
class TestReadmeCanonical < Test::Unit::TestCase
  GEM_ROOT = File.expand_path("../..", __dir__)

  def test_readme_l26_to_l34_runs_and_returns_non_zero_client
    Dir.mktmpdir do |dir|
      script = File.join(dir, "readme_canonical.rb")
      # README L27-33 verbatim, plus a final puts so we can assert the
      # client value back from stdout. The 3 lines under inspection are
      # marked CANONICAL and must match README exactly.
      File.write(script, <<~RUBY)
        # CANONICAL — must match README.md L27-33 verbatim
        require "apple_sdk_mac"

        # First-time: declare you want to call this API
        Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

        # Use it
        client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
        # END CANONICAL

        puts "CLIENT_REF=\#{client.inspect}"
      RUBY

      out, err, status = Open3.capture3(
        { "RUBY_BOX" => "1" },
        "bundle", "exec", "ruby", script,
        chdir: GEM_ROOT
      )

      assert_equal 0, status.exitstatus,
        "README canonical snippet exited #{status.exitstatus}.\nstdout:\n#{out}\nstderr:\n#{err}"

      m = out.match(/CLIENT_REF=(\S+)$/)
      assert_not_nil m, "no CLIENT_REF in stdout:\n#{out}"
      client_repr = m[1]

      # MIDIClientRef is a UInt32 ObjectRef — Ruby surfaces it as Integer.
      # README claim is "non-zero MIDIClientRef"; nil or 0 means MIDI failed.
      refute_equal "nil", client_repr, "MIDIClientCreate returned nil"
      refute_equal "0",   client_repr, "MIDIClientCreate returned 0"
      assert_match(/\A\d+\z/, client_repr,
        "expected integer-shaped MIDIClientRef, got: #{client_repr}")
      assert client_repr.to_i > 0,
        "expected non-zero MIDIClientRef, got: #{client_repr}"
    end
  end

  # README L29-30 second declaration form: the non-canonical alternative
  # paths must NOT regress when the canonical one is taken first. Smoke
  # the discover idempotency: calling discover twice for the same symbol
  # is a no-op and the second call's MIDIClientCreate still works.
  def test_canonical_snippet_is_idempotent_under_double_discover
    Dir.mktmpdir do |dir|
      script = File.join(dir, "double_discover.rb")
      File.write(script, <<~'RUBY')
        require "apple_sdk_mac"
        Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
        Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
        c = Apple::CoreMIDI.MIDIClientCreate("Twice", nil, nil)
        puts "OK=#{c.is_a?(Integer) && c > 0}"
      RUBY

      out, err, status = Open3.capture3(
        { "RUBY_BOX" => "1" },
        "bundle", "exec", "ruby", script,
        chdir: GEM_ROOT
      )
      assert_equal 0, status.exitstatus, "double-discover exited #{status.exitstatus}\n#{err}"
      assert_match(/^OK=true$/, out, "expected OK=true; got:\n#{out}")
    end
  end
end
