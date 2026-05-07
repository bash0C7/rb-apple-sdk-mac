# frozen_string_literal: true
require "reline"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/doc_resolver"

module AppleSDKMac
  module IRB
    # Renders the popup right-side doc preview from the hovered Apple
    # SDK candidate. The proc form (#to_proc) is registered with
    # Reline.add_dialog_proc(:show_doc, ..., DEFAULT_DIALOG_CONTEXT) and
    # piggybacks on the autocomplete dialog's pushed context (cursor
    # pos, candidate list, pointer, dialog) so we read the user's
    # current hover target without intercepting key events.
    class DocDialog
      DEFAULT_WIDTH = 60

      def initialize(resolver:, prefetcher: nil, llm_resolver: nil, width: DEFAULT_WIDTH)
        @resolver = resolver
        @prefetcher = prefetcher
        @llm_resolver = llm_resolver
        @width = width
      end

      # Pure render entry-point — easy to unit-test without a Reline
      # DialogProcScope. Returns Reline::DialogRenderInfo or nil.
      # Side-effect: kicks the prefetcher (if injected) regardless of
      # whether documentation is available, so first-call latency on
      # an undocumented Apple symbol still gets the prefetch benefit.
      # Resolution order: KB-driven primary resolver, then llm_resolver
      # for Swift-overlay / Ruby stdlib symbols the KB cannot answer.
      def render(matched:, cursor_pos:, max_height:, autocomplete_dialog: nil, max_width: @width)
        @prefetcher&.prefetch(matched)
        doc = @resolver.resolve(matched)
        doc = @llm_resolver.resolve(matched) if (doc.nil? || doc.to_s.strip.empty?) && @llm_resolver
        return nil if doc.nil? || doc.to_s.strip.empty?
        contents = wrap_text(doc, max_width).take(max_height)
        return nil if contents.empty?
        x = anchor_x(autocomplete_dialog, cursor_pos)
        Reline::DialogRenderInfo.new(
          pos: Reline::CursorPos.new(x, cursor_pos.y),
          contents: contents,
          width: max_width,
          bg_color: "49"
        )
      end

      def wrap_text(text, width)
        normalized = text.to_s.gsub(/\s+/, " ").strip
        return [] if normalized.empty?
        lines = []
        current = +""
        normalized.split(" ").each do |word|
          tentative = current.empty? ? word : "#{current} #{word}"
          if tentative.length > width && !current.empty?
            lines << current
            current = word
          else
            current = tentative
          end
        end
        lines << current unless current.empty?
        lines
      end

      def to_proc
        dialog_obj = self
        ->() {
          # Defensive: never trap keys (we only render).
          dialog.trap_key = nil

          # When the user is just moving the cursor without an active
          # autocomplete journey, the popup's right-side dialog has no
          # candidate to describe — skip rendering.
          return nil if just_cursor_moving && completion_journey_data.nil?

          # The :autocomplete dialog pushes [cursor_pos, result, pointer,
          # dialog] onto Reline::DEFAULT_DIALOG_CONTEXT. We pop them here
          # to learn which candidate is currently highlighted.
          cursor_pos_to_render, result, pointer, autocomplete_dialog = context.pop(4)
          return nil if result.nil? || pointer.nil? || pointer < 0
          matched = result[pointer]

          dialog_obj.render(
            matched: matched,
            cursor_pos: cursor_pos_to_render,
            max_height: preferred_dialog_height,
            autocomplete_dialog: autocomplete_dialog
          )
        }
      end

      private

      def anchor_x(autocomplete_dialog, cursor_pos)
        if autocomplete_dialog &&
           autocomplete_dialog.respond_to?(:column) && autocomplete_dialog.column &&
           autocomplete_dialog.respond_to?(:width)  && autocomplete_dialog.width
          autocomplete_dialog.column + autocomplete_dialog.width
        else
          cursor_pos.x
        end
      end
    end
  end
end
