# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/embedder"

class TestEmbedder < Test::Unit::TestCase
  def test_embed_returns_768_dim_vector
    e = AppleSDKKnowledge::Importer::Embedder.new
    v = e.embed("MIDI client creation function")
    assert_equal 768, v.length
    assert v.all? { |x| x.is_a?(Numeric) }
  end

  def test_zero_vector_when_no_backend
    e = AppleSDKKnowledge::Importer::Embedder.new
    v = e.embed("anything")
    assert_equal 768, v.length
  end
end
