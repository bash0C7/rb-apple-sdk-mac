# frozen_string_literal: true

module AppleSDKKnowledge
  class Search
    def initialize(store)
      @store = store
    end

    def lexical(framework:, query:, limit: 5)
      @store.fts_search(framework, query, limit: limit)
    end
  end
end
