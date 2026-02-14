# frozen_string_literal: true
require_relative 'module'
require_relative 'predict'
require_relative 'code_interpreter'
require_relative 'repl_types'
require_relative 'mixins/type_coercion'
module DSPy
  class RLM < DSPy::Module
    # NOTE: These require_relative calls must be AFTER the class definition
    # so that DSPy::RLM is already defined with the correct superclass.
    # The sub-files reopen `class RLM` without specifying a superclass.
    require_relative 'rlm/instructions'
    require_relative 'rlm/signatures'
    require_relative 'interpreters/ruby_repl'
    require_relative 'interpreters/mock_repl'

    include DSPy::Mixins::TypeCoercion
    attr_reader :generate_action, :extract, :iteration_count, :llm_call_count

    def initialize(
      signature_class,
      max_iterations: 20,
      max_llm_calls: 50,
      max_output_chars: 10_000,
      timeout: nil,
      verbose: false,
      tools: [],
      sub_lm: nil,
      interpreter: nil
    )
      @signature_class = signature_class
      @max_iterations = max_iterations
      @max_llm_calls = max_llm_calls
      @max_output_chars = max_output_chars
      @verbose = verbose
      @sub_lm = sub_lm
      @user_interpreter = interpreter
      @user_tools = normalize_tools(tools)
      @timeout = timeout
      @iteration_count = 0
      @llm_call_count = 0
      @start_time = nil

      # Build the two internal predictors
      action_sig = Signatures.build_action_signature(
        signature_class, max_llm_calls: max_llm_calls, tool_docs: format_tool_docs
      )
      extract_sig = Signatures.build_extract_signature(signature_class)

      @generate_action = DSPy::Predict.new(action_sig)
      @extract = DSPy::Predict.new(extract_sig)
    end

    def forward(**input_args)
      @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @iteration_count = 0
      @llm_call_count = 0
      variables = build_variables(**input_args)
      execution_tools = make_llm_tools.merge(@user_tools)
      interpreter = @user_interpreter || Interpreters::RubyREPL.new(
        tools: execution_tools,
        output_fields: output_field_names
      )

      begin
        interpreter.start
        # Inject input variables once
        interpreter.execute("nil", variables: input_args) rescue nil
        history = REPLHistory.new(max_output_chars: @max_output_chars)
        @max_iterations.times do |i|
          check_timeout!
          @iteration_count = i + 1
          result = execute_iteration(interpreter, variables, history, i, output_field_names)
          if result.is_a?(DSPy::Prediction)
            return result
          end
          history = result # updated REPLHistory
        end

        # Max iterations reached - use extract fallback
        log("Max iterations reached, using extract fallback") if @verbose
        extract_fallback(variables, history, output_field_names)
      ensure
        interpreter.shutdown unless @user_interpreter
      end
    end

    def named_predictors
      [["generate_action", @generate_action], ["extract", @extract]]
    end

    def predictors
      named_predictors.map { |(_, p)| p }
    end

    private

    def check_timeout!
      return unless @timeout && @start_time
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time
      if elapsed > @timeout
        raise CodeInterpreterError, "RLM timeout: #{elapsed.round(1)}s exceeded #{@timeout}s limit"
      end
    end

    def elapsed_time
      return 0 unless @start_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time
    end

    def execute_iteration(interpreter, variables, history, iteration, output_field_names)
      variables_info = variables.map(&:format).join("\n\n")

      log("=== Iteration #{iteration + 1}/#{@max_iterations} ===") if @verbose

      # 1. Generate action (reasoning + code)
      action = @generate_action.call(
        variables_info: variables_info,
        repl_history: history.to_s,
        iteration: "#{iteration + 1}/#{@max_iterations}"
      )

      code = action.code
      log("Code:\n#{code}") if @verbose

      # 2. Execute in interpreter
      begin
        result = interpreter.execute(code)
      rescue CodeInterpreterError => e
        result = "[Error] #{e.message}"
      end

      log("Output: #{result.is_a?(FinalOutput) ? 'FINAL' : result.to_s[0, 200]}") if @verbose

      # 3. Process result
      process_execution_result(action, result, history, output_field_names, code)
    end

    def process_execution_result(action, result, history, output_field_names, code)
      reasoning = begin; action.reasoning; rescue; ""; end

      # Handle FinalOutput (SUBMIT was called)
      if result.is_a?(FinalOutput)
        parsed, error = process_final_output(result, output_field_names)
        if error
          return history.append(reasoning: reasoning, code: code, output: error)
        end

        final_history = history.append(
          reasoning: reasoning, code: code, output: "FINAL: #{parsed.inspect}"
        )
        return build_prediction(parsed, final_history, reasoning)
      end

      # Normal output or error — append to history and continue
      history.append(reasoning: reasoning, code: code, output: result.to_s)
    end

    def process_final_output(final_output, output_field_names)
      raw = final_output.output

      unless raw.is_a?(Hash)
        return [nil, "[Error] SUBMIT returned #{raw.class}, expected keyword arguments. Use: SUBMIT(#{output_field_names.join(': ..., ')}: ...)"]
      end

      # Normalize keys to strings
      raw_str = raw.transform_keys(&:to_s)

      # Check all fields present
      missing = output_field_names - raw_str.keys
      unless missing.empty?
        return [nil, "[Error] Missing fields: #{missing.join(', ')}. Use SUBMIT(#{output_field_names.join(': ..., ')}: ...)"]
      end

      # Coerce each field using dspy.rb's type system
      parsed = {}
      type_errors = []
      output_field_names.each do |name|
        descriptor = @signature_class.output_field_descriptors[name.to_sym] || @signature_class.output_field_descriptors[name.to_s]
        value = raw_str[name]
        begin
          coerced = coerce_value_to_type(value, descriptor.type)
          parsed[name.to_sym] = coerced
        rescue StandardError => e
          type_errors << "#{name}: expected #{descriptor.type}, got #{value.class} — #{e.message}"
        end
      end

      return [nil, "[Type Error] #{type_errors.join('; ')}"] unless type_errors.empty?
      [parsed, nil]
    end

    def extract_fallback(variables, history, output_field_names)
      variables_info = variables.map(&:format).join("\n\n")
      extract_pred = @extract.call(
        variables_info: variables_info,
        repl_history: history.to_s
      )

      parsed = output_field_names.each_with_object({}) do |name, h|
        h[name.to_sym] = extract_pred.send(name)
      end

      build_prediction(parsed, history, "Extract fallback — max iterations reached")
    end

    def build_prediction(parsed_output, history, final_reasoning)
      DSPy::Prediction.new(
        @signature_class,
        **parsed_output
      )
    end

    def build_variables(**input_args)
      input_args.map do |name, value|
        field_info = @signature_class.input_field_descriptors[name.to_sym] || @signature_class.input_field_descriptors[name.to_s]
        REPLVariable.from_value(name, value, field_info: field_info)
      end
    end

    def make_llm_tools
      call_count = 0
      mutex = Mutex.new
      max = @max_llm_calls
      lm = @sub_lm

      llm_query = lambda do |prompt|
        raise "llm_query: prompt cannot be empty" if prompt.to_s.strip.empty?
        mutex.synchronize do
          call_count += 1
          if call_count > max
            raise "LLM call limit exceeded (#{max}). Use Ruby code for aggregation instead."
          end
        end
        target_lm = lm || DSPy.config.lm
        raise "No LM configured for llm_query" unless target_lm
        response = target_lm.chat(prompt: prompt)
        response.text
      end

      { "llm_query" => llm_query }
    end

    def normalize_tools(tools)
      case tools
      when Hash then tools
      when Array
        tools.each_with_object({}) do |tool, h|
          name = tool.respond_to?(:tool_name) ? tool.tool_name : tool.class.name.split("::").last.downcase
          h[name] = tool.respond_to?(:call) ? tool.method(:call) : tool
        end
      else
        {}
      end
    end

    def format_tool_docs
      @user_tools.map { |name, _| "- `#{name}(...)` — user-provided tool" }.join("\n")
    end

    def log(msg)
      $stderr.puts "[RLM] #{msg}" if @verbose
    end
  end
end
