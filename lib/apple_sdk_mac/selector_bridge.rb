# frozen_string_literal: true

module AppleSDKMac
  # Single canonical implementation of ObjC→Swift selector name conversion
  # and acronym-aware first-word lowercase. Stateless module-level methods.
  #
  # Used by both the public Apple.discover synthesis path (public_api.rb)
  # and the TemplateGenerator's swift_init_call / swift_call_for_class_method
  # selector→Swift label rewrites (template_generator.rb). One canonical
  # implementation keeps acronym handling (URL→url, IRB→irb, XMLDoc→xmlDoc)
  # and init-form detection (initWithFrame: → init form) consistent across
  # both call sites.
  module SelectorBridge
    module_function

    # Selector → Swift-form method name converter (Apple ObjC→Swift API
    # bridging convention).
    # - single-segment (`stringWithUTF8String:`) → `stringWithUTF8String`
    # - multi-segment init (`initWithCGImage:options:`) → `init(cgImage:options:)`
    #   "init" prefix stripped, optional "With" / "From" / "By" / "Using" /
    #   "For" stripped, first label lowerCamelCase per Apple's bridging rule
    # - multi-segment non-init (`requestWithURL:cachePolicy:`) →
    #   `requestWithURL(cachePolicy:)`
    def canonical_method_name(selector)
      s = selector.to_s
      parts = s.split(":", -1).reject(&:empty?)
      return s if parts.empty?
      return parts[0] if parts.size == 1
      if parts[0].start_with?("init")
        head = parts[0].sub(/\Ainit/, "").sub(/\A(With|From|By|Using|For)/, "")
        head = lower_first_camel(head)
        labels = head.empty? ? parts[1..] : ([head] + parts[1..])
        "init(" + labels.map { |l| "#{l}:" }.join + ")"
      else
        first = parts[0]
        rest = parts[1..]
        "#{first}(" + rest.map { |l| "#{l}:" }.join + ")"
      end
    end

    # Apple ObjC→Swift bridging の acronym handling。
    # - `Image` → `image` (no acronym run)
    # - `CGImage` → `cgImage` (2-letter acronym + Pascal word)
    # - `URL` → `url` (all-uppercase word)
    # - `URLString` → `urlString` (3-letter acronym + Pascal word)
    # - `UTF8String` → `utf8String` (acronym followed by digit: lower entire run)
    # - `IRB` → `irb`、 `H` → `h`、 `""` → `""`
    def lower_first_camel(s)
      return "" if s.empty?
      m = s.match(/\A[A-Z]+/)
      return s[0].downcase + (s[1..] || "") unless m
      run = m[0]
      return s.downcase if run.length == s.length
      return s[0].downcase + s[1..] if run.length == 1
      next_char = s[run.length]
      if next_char =~ /[a-z]/
        # Last upper letter starts the next word: keep it, lower the rest.
        run[0..-2].downcase + run[-1] + s[run.length..]
      else
        # Acronym followed by digit / non-letter → lower the whole run.
        run.downcase + s[run.length..]
      end
    end
  end
end
