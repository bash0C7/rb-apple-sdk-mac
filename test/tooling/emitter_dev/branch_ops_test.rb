# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "emitter_dev/branch_ops"

class BranchOpsTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    Dir.chdir(@tmpdir) do
      system "git init -q --initial-branch=main"
      system "git config user.email t@x"
      system "git config user.name t"
      File.write("a", "a"); system "git add a && git commit -qm init"
    end
    @prev_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@prev_pwd)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_derive_name_basic
    cand = { "mode" => "add", "summary" => "AVCaptureDevice devicesWithMediaType static emitter" }
    name = EmitterDev::BranchOps.derive_name(cand)
    assert_match %r{\Aemitter/add-avcapturedevice-deviceswithmediatype-static-emitter-\d{8}\z}, name
  end

  def test_derive_name_collision_uses_suffix
    system "git checkout -qb emitter/add-foo-#{Time.now.strftime('%Y%m%d')} 2>/dev/null"
    system "git checkout -q main"
    cand = { "mode" => "add", "summary" => "foo" }
    name = EmitterDev::BranchOps.derive_name(cand)
    assert_match %r{-2\z}, name, "expected -2 suffix when base name exists"
  end
end
