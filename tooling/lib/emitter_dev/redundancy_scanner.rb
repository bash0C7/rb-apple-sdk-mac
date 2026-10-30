# frozen_string_literal: true
require "prism"

module EmitterDev
  class RedundancyScanner
    BODY_MIN_LEN          = 10
    SIMILARITY_THRESHOLD  = 0.7
    OVERLAP_MIN_METHODS   = 2
    TWIN_SCORE            = 12
    OVERLAP_SCORE         = 10

    def initialize(file_path)
      @file_path = file_path
    end

    def scan
      classes = collect_classes(Prism.parse_file(@file_path).value)

      findings = []
      findings.concat(scan_twin_private_helpers(classes))
      findings.concat(scan_class_pair_method_overlap(classes))
      findings
    end

    private

    def collect_classes(node, acc = [])
      if node.is_a?(Prism::ClassNode)
        acc << { name: node.constant_path.slice.split("::").last, methods: collect_methods(node) }
      end
      node.compact_child_nodes.each { |c| collect_classes(c, acc) }
      acc
    end

    def collect_methods(class_node)
      methods = {}
      walk(class_node) do |n|
        next unless n.is_a?(Prism::DefNode)
        methods[n.name.to_s] = n.body ? n.body.slice : ""
      end
      methods
    end

    def walk(node, &block)
      block.call(node)
      node.compact_child_nodes.each { |c| walk(c, &block) }
    end

    def scan_twin_private_helpers(classes)
      bodies = []
      classes.each do |c|
        c[:methods].each do |mname, body|
          bodies << { class: c[:name], method: mname, body: body.gsub(/\s+/, " ").strip }
        end
      end

      twins = []
      bodies.combination(2).each do |a, b|
        next if a[:class] == b[:class]
        next unless similar?(a[:body], b[:body])

        twins << {
          heuristic: :twin_private_helper,
          classes:   [a[:class], b[:class]],
          methods:   [a[:method], b[:method]],
          score:     TWIN_SCORE,
        }
      end
      twins
    end

    def scan_class_pair_method_overlap(classes)
      pairs = []
      classes.combination(2).each do |a, b|
        common = a[:methods].keys & b[:methods].keys
        next if common.size < OVERLAP_MIN_METHODS

        pairs << {
          heuristic:      :class_pair_method_overlap,
          classes:        [a[:name], b[:name]],
          common_methods: common,
          score:          OVERLAP_SCORE,
        }
      end
      pairs
    end

    def similar?(a, b)
      return false if a.length < BODY_MIN_LEN || b.length < BODY_MIN_LEN
      _, longer = [a, b].sort_by(&:length)
      common    = longer.length - levenshtein(a, b)
      common.to_f / longer.length > SIMILARITY_THRESHOLD
    end

    def levenshtein(a, b)
      m = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
      (0..a.length).each { |i| m[i][0] = i }
      (0..b.length).each { |j| m[0][j] = j }
      (1..a.length).each do |i|
        (1..b.length).each do |j|
          cost   = a[i - 1] == b[j - 1] ? 0 : 1
          m[i][j] = [m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + cost].min
        end
      end
      m[a.length][b.length]
    end
  end
end
