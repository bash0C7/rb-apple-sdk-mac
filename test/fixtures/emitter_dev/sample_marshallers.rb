# frozen_string_literal: true
# Fixture for redundancy_scanner_test. NOT real production code.
module Sample
  class IntMarshaller
    def in_load
      "x"
    end

    private

    def scalar_type_token(raw)
      raw.gsub(/const|nullable/, "").strip.split("*").first.strip
    end
  end

  class FloatMarshaller
    def in_load
      "y"
    end

    private

    def scalar_float_type(raw)
      raw.gsub(/const|nullable/, "").strip.split("*").first.strip
    end
  end

  class BlockA
    def in_load
      "a"
    end

    def call_arg
      "a"
    end
  end

  class BlockAVoid
    def in_load
      "a"
    end

    def call_arg
      "a"
    end
  end
end
