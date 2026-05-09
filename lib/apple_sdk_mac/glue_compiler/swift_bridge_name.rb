# frozen_string_literal: true
require_relative "swift_bridge_overrides"

module AppleSDKMac
  class GlueCompiler
    # Phase 4b — high-priority resolvers for ObjC selector → Swift call
    # expression. Tries KB-stored swift_imported_name first, then manual
    # SWIFT_BRIDGE_OVERRIDES. Returns nil when both miss; caller (template
    # generator) then falls through to its historical heuristic.
    #
    # Stateless module per shallow tenet — no dependency injection ceremony,
    # caller passes kc / framework / klass / selector / params directly.
    module SwiftBridgeName
      module_function

      # Returns the Swift call expression string, or nil if neither KB nor
      # overrides have a match.
      def resolve(framework:, klass:, selector:, params:, kc: nil)
        from_kb(framework, klass, selector, params, kc) ||
          from_overrides(framework, klass, selector, params)
      end

      def from_kb(framework, klass, selector, params, kc)
        return nil unless kc && framework
        return nil unless kc.respond_to?(:lookup_swift_imported_name)
        name = kc.lookup_swift_imported_name(framework: framework, klass: klass, selector: selector)
        return nil if name.nil? || name.to_s.empty?

        rebuild_from_swift_imported_name(klass, name, params)
      end

      def from_overrides(framework, klass, selector, params)
        key = [framework.to_s, klass.to_s, selector.to_s]
        tmpl = SWIFT_BRIDGE_OVERRIDES[key]
        return nil unless tmpl
        args = params.each_index.map { |i| "arg#{i}" }
        format(tmpl, *args)
      end

      # Parse a Swift imported name like "devices(for:)" / "init(string:)" /
      # "shared()" into a call expression bound to `arg0..argN` slots.
      # Underscore labels (`_:`) emit a positional argument.
      def rebuild_from_swift_imported_name(klass, name, params)
        m = name.match(/\A(\w+)\(([^)]*)\)\z/)
        return nil unless m
        method_name = m[1]
        labels      = m[2].split(",").map { |l| l.strip.delete_suffix(":") }

        args = params.each_index.map { |i| "arg#{i}" }
        if labels.empty?
          method_name == "init" ? "#{klass}()" : "#{klass}.#{method_name}()"
        else
          paired = labels.zip(args).map { |l, a| l.empty? || l == "_" ? a.to_s : "#{l}: #{a}" }.join(", ")
          method_name == "init" ? "#{klass}(#{paired})" : "#{klass}.#{method_name}(#{paired})"
        end
      end
    end
  end
end
