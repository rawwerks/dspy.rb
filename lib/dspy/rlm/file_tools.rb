# frozen_string_literal: true

module DSPy
  class RLM
    # Built-in tools for coding agent use cases.
    # Usage: DSPy::RLM.new(sig, tools: DSPy::RLM::FileTools.new("/path/to/repo"))
    class FileTools
      attr_reader :root

      def initialize(root_dir)
        @root = File.expand_path(root_dir)
      end

      def to_tools
        {
          "read_file" => method(:read_file),
          "list_dir" => method(:list_dir),
          "grep_files" => method(:grep_files),
          "file_info" => method(:file_info)
        }
      end

      TOOL_DOCS = {
        "read_file" => "read_file(path, max_chars: 50000) — read a file's contents. Returns string.",
        "list_dir" => "list_dir(path=\".\", recursive: false) — list directory entries. Returns newline-separated string.",
        "grep_files" => "grep_files(pattern, path: \".\", include_ext: nil) — regex search across files. Returns \"file:line_num:content\" lines.",
        "file_info" => "file_info(path) — get file size, line count, type."
      }.freeze

      def tool_descriptions
        TOOL_DOCS
      end

      def read_file(path, max_chars: 50_000)
        full = resolve(path)
        content = File.read(full)
        if content.length > max_chars
          content[0, max_chars] + "\n... (truncated at #{max_chars} chars, total #{content.length})"
        else
          content
        end
      end

      def list_dir(path = ".", recursive: false)
        full = resolve(path)
        if recursive
          Dir.glob(File.join(full, "**", "*")).select { |f| File.file?(f) }
            .map { |f| f.sub("#{@root}/", "") }.sort.join("\n")
        else
          Dir.entries(full).reject { |e| e.start_with?(".") }.sort.join("\n")
        end
      end

      def grep_files(pattern_pos = nil, path: ".", include_ext: nil, pattern: nil)
        pattern = pattern_pos || pattern
        raise "grep_files requires a pattern (first arg or pattern: keyword)" if pattern.nil?
        full = resolve(path)
        glob = include_ext ? File.join(full, "**", "*#{include_ext}") : File.join(full, "**", "*")
        re = Regexp.new(pattern)
        results = []
        Dir.glob(glob).select { |f| File.file?(f) }.each do |file|
          begin
            File.readlines(file, encoding: 'utf-8').each_with_index do |line, i|
              if line.valid_encoding? && line.match?(re)
                relative = file.sub("#{@root}/", "")
                results << "#{relative}:#{i + 1}:#{line.rstrip}"
              end
            end
          rescue ArgumentError, Encoding::InvalidByteSequenceError
            # Skip binary/non-UTF-8 files
          end
        end
        results.join("\n")
      end

      def file_info(path)
        full = resolve(path)
        stat = File.stat(full)
        lines = File.file?(full) ? File.readlines(full).size : 0
        "path: #{path}\nsize: #{stat.size} bytes\nlines: #{lines}\ntype: #{stat.ftype}"
      end

      private

      def resolve(path)
        full = File.expand_path(path, @root)
        unless full.start_with?(@root)
          raise "Access denied: #{path} is outside #{@root}"
        end
        raise "Not found: #{path}" unless File.exist?(full)
        full
      end
    end
  end
end
