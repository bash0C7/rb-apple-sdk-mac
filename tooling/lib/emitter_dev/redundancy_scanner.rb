# frozen_string_literal: true
require "parser/current"

# Scans a Ruby source file (typically marshallers.rb) for redundancy candidates
# the HITL trim-mode workflow can act on. Two heuristics:
#
#   :twin_private_helper       — two classes hold methods whose bodies are
#                                near-identical (Levenshtein similarity > 0.7,
#                                both bodies length >= 10 to filter trivials).
#   :class_pair_method_overlap — two classes share >= 2 method names.
#
# Returns Array<Hash> findings with :heuristic, :score, plus heuristic-specific
# fields. Caller (CandidateRanker.rank_trim) wraps each into a candidate.
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
      source  = File.read(@file_path)
      ast     = Parser::CurrentRuby.parse(source)
      classes = collect_classes(ast)

      findings = []
      findings.concat(scan_twin_private_helpers(classes))
      findings.concat(scan_class_pair_method_overlap(classes))
      findings
    end

    private

    def collect_classes(node, acc = [])
      return acc unless node.is_a?(Parser::AST::Node)
      if node.type == :class
        name_node = node.children[0]
        cls_name  = name_node.children.last.to_s
        acc << { name: cls_name, methods: collect_methods(node) }
      end
      node.children.each { |c| collect_classes(c, acc) }
      acc
    end

    def collect_methods(class_node)
      methods = {}
      walk(class_node) do |n|
        next unless n.type == :def
        mname     = n.children[0].to_s
        body_node = n.children[2]
        methods[mname] = body_node ? body_node.loc.expression.source : ""
      end
      methods
    end

    def walk(node, &block)
      return unless node.is_a?(Parser::AST::Node)
      block.call(node)
      node.children.each { |c| walk(c, &block) }
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
