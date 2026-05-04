# frozen_string_literal: true

module AppleSDKMac
  class OpaqueRef
    def initialize(counter_handle = nil)
      @counter_handle = counter_handle
      ObjectSpace.define_finalizer(self, self.class.finalizer(counter_handle))
    end

    def self.finalizer(counter_handle)
      proc {
        AppleSDKMacRuntime.arc_counter_bump(counter_handle) if counter_handle
      }
    end
  end
end
