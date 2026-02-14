# frozen_string_literal: true

require 'stringio'
require 'json'
require_relative '../code_interpreter'

module DSPy
  module Interpreters
    class RubyREPL
      include CodeInterpreter

      # Dangerous methods/constants to block in sandbox
      BLOCKED_METHODS = %w[system exec fork spawn `].freeze
      BLOCKED_CONSTANTS = %w[].freeze # keep permissive for now

      # Safe stdlib requires
      ALLOWED_REQUIRES = %w[
        json set date time uri ostruct digest base64 csv
        pathname tempfile fileutils stringio strscan
        net/http net/https open-uri
      ].freeze

      attr_reader :tools

      def initialize(tools: {}, output_fields: [])
        @tools = tools
        @output_fields = output_fields # Array of field name strings
        @binding = nil
        @started = false
        @final_output = nil
      end

      def start
        return if @started
        @binding = create_sandbox_binding
        register_submit
        register_tools
        @started = true
      end

      def execute(code, variables: {})
        start unless @started
        inject_variables(variables) unless variables.empty?
        @final_output = nil

        code = strip_code_fences(code)
        stdout, result, error = capture_execution(code)

        return FinalOutput.new(@final_output) if @final_output

        if error
          raise CodeInterpreterError, error
        end

        # Prefer stdout; fall back to eval result
        output = stdout.empty? ? result.to_s : stdout.chomp
        output = "(no output - did you forget to print/puts?)" if output.strip.empty?
        output
      end

      def shutdown
        @binding = nil
        @started = false
        @final_output = nil
      end

      private

      def create_sandbox_binding
        b = TOPLEVEL_BINDING.dup

        # Inject safe require wrapper
        allowed = ALLOWED_REQUIRES
        allowed_list = allowed
        b.eval(<<~'RUBY', "(rlm-setup)", 1)
          def require(name)
            allowed = %w[json set date time uri ostruct digest base64 csv pathname tempfile fileutils stringio strscan net/http net/https open-uri]
            unless allowed.include?(name.to_s)
              raise "require '\#{name}' is not allowed in the sandbox. Allowed: \#{allowed.join(', ')}"
            end
            Kernel.require(name)
          end
        RUBY

        b
      end

      def register_submit
        # Capture reference for closure
        repl = self
        output_fields = @output_fields

        @binding.eval(<<~RUBY, "(rlm-submit)", 1)
          define_method(:SUBMIT) do |**kwargs|
            # Validate required fields
            missing = #{output_fields.inspect} - kwargs.keys.map(&:to_s)
            unless missing.empty?
              raise "SUBMIT missing required fields: \#{missing.join(', ')}. Expected: SUBMIT(#{output_fields.join(': ..., ')}: ...)"
            end
            # Signal to host
            ObjectSpace._id2ref(#{repl.object_id}).send(:signal_final_output, kwargs)
            "SUBMITTED"
          end
        RUBY
      end

      def register_tools
        @tools.each do |name, callable|
          @binding.local_variable_set(:"__tool_#{name}", callable)
          @binding.eval(<<~RUBY, "(rlm-tool-#{name})", 1)
            define_method(:#{name}) do |*args, **kwargs, &block|
              __tool_#{name}.call(*args, **kwargs, &block)
            end
          RUBY
        end
      end

      def inject_variables(variables)
        variables.each do |name, value|
          @binding.local_variable_set(name.to_sym, value)
        end
      end

      def signal_final_output(kwargs)
        @final_output = kwargs
      end

      def capture_execution(code)
        stdout_capture = StringIO.new
        old_stdout = $stdout
        $stdout = stdout_capture

        begin
          result = eval(code, @binding, "(rlm)", 1) # rubocop:disable Security/Eval
          [stdout_capture.string, result, nil]
        rescue SyntaxError => e
          [stdout_capture.string, nil, "SyntaxError: #{e.message}"]
        rescue StandardError => e
          [stdout_capture.string, nil, "#{e.class}: #{e.message}"]
        ensure
          $stdout = old_stdout
        end
      end

      def strip_code_fences(code)
        code = code.strip
        # Remove opening fence: ```ruby or ```
        if code.start_with?("```")
          code = code.sub(/\A```\w*\n?/, "")
        end
        # Remove closing fence
        if code.end_with?("```")
          code = code.sub(/\n?```\z/, "")
        end
        code
      end
    end
  end
end
