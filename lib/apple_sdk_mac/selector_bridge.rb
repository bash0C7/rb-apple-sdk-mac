# frozen_string_literal: true

module AppleSDKMac
  module SelectorBridge
    module_function

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

    def lower_first_camel(s)
      return "" if s.empty?
      m = s.match(/\A[A-Z]+/)
      return s[0].downcase + (s[1..] || "") unless m
      run = m[0]
      return s.downcase if run.length == s.length
      return s[0].downcase + s[1..] if run.length == 1
      next_char = s[run.length]
      if next_char =~ /[a-z]/
        run[0..-2].downcase + run[-1] + s[run.length..]
      else
        run.downcase + s[run.length..]
      end
    end
  end
end
