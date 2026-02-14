# frozen_string_literal: true

require 'json'

module DSPy
  # Metadata about a variable available in the REPL sandbox.
  # Built from actual values + optional field info from the signature.
  class REPLVariable
    attr_reader :name, :type_name, :desc, :total_length, :preview

    PREVIEW_CHARS = 1000

    def initialize(name:, type_name:, desc: "", total_length: 0, preview: "")
      @name = name
      @type_name = type_name
      @desc = desc
      @total_length = total_length
      @preview = preview
    end

    def self.from_value(name, value, field_info: nil, preview_chars: PREVIEW_CHARS)
      value_str = case value
      when Hash, Array
        begin
          JSON.pretty_generate(value)
        rescue
          value.inspect
        end
      else
        value.to_s
      end

      preview = if value_str.length > preview_chars
        half = preview_chars / 2
        "#{value_str[0, half]}\n... (#{value_str.length - preview_chars} chars omitted) ...\n#{value_str[-(half)..]}"
      else
        value_str
      end

      new(
        name: name.to_s,
        type_name: value.class.name,
        desc: field_info&.description || "",
        total_length: value_str.length,
        preview: preview
      )
    end

    def format
      lines = ["Variable: `#{name}` (access it directly in code)"]
      lines << "Type: #{type_name}"
      lines << "Description: #{desc}" unless desc.empty?
      formatted_len = total_length.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      lines << "Total length: #{formatted_len} characters"
      lines << "Preview:\n```\n#{preview}\n```"
      lines.join("\n")
    end
  end

  # One step in the REPL interaction history.
  class REPLEntry
    attr_reader :reasoning, :code, :output

    def initialize(reasoning: "", code:, output:)
      @reasoning = reasoning
      @code = code
      @output = output
    end

    def format(index, max_output_chars: 10_000)
      parts = ["=== Step #{index + 1} ==="]
      parts << "Reasoning: #{reasoning}" unless reasoning.empty?
      parts << "Code:\n```ruby\n#{code}\n```"
      parts << format_output(output, max_output_chars)
      parts.join("\n")
    end

    def to_h
      { reasoning: reasoning, code: code, output: output }
    end

    private

    def format_output(text, max_chars)
      raw_len = text.length
      display = if raw_len > max_chars
        half = max_chars / 2
        omitted = raw_len - max_chars
        "#{text[0, half]}\n\n... (#{omitted} characters omitted) ...\n\n#{text[-(half)..]}"
      else
        text
      end
      "Output (#{raw_len} chars):\n#{display}"
    end
  end

  # Immutable history of REPL interactions. Append returns a new instance.
  class REPLHistory
    attr_reader :entries, :max_output_chars

    def initialize(entries: [], max_output_chars: 10_000)
      @entries = entries.freeze
      @max_output_chars = max_output_chars
    end

    def append(reasoning: "", code:, output:)
      new_entry = REPLEntry.new(reasoning: reasoning, code: code, output: output)
      REPLHistory.new(entries: entries + [new_entry], max_output_chars: max_output_chars)
    end

    def format
      return "You have not interacted with the REPL environment yet." if entries.empty?
      entries.each_with_index.map { |e, i| e.format(i, max_output_chars: max_output_chars) }.join("\n\n")
    end

    # For dspy.rb's prompt serialization
    def to_s
      format
    end

    def empty?
      entries.empty?
    end

    def size
      entries.size
    end
  end
end
