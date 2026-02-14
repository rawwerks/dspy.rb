# frozen_string_literal: true

module DSPy
  # Wraps a final output from SUBMIT() in the sandbox.
  # When CodeInterpreter#execute returns a FinalOutput, the RLM loop stops.
  class FinalOutput
    attr_reader :output

    def initialize(output)
      @output = output
    end
  end

  # Raised when sandbox code execution fails (runtime errors, not syntax).
  class CodeInterpreterError < RuntimeError; end

  # Protocol for code interpreters. Any interpreter must implement:
  #   #tools   → Hash[String, Callable]
  #   #start   → void (optional, can be lazy)
  #   #execute(code, variables:) → String | FinalOutput
  #   #shutdown → void (optional cleanup)
  #
  # Design:
  #   - execute returns FinalOutput when SUBMIT is called (loop termination signal)
  #   - variables parameter takes typed Ruby objects, not strings
  #   - State persists across execute calls within one session
  #   - Thread safety is the caller's responsibility (one interpreter per forward() call)
  module CodeInterpreter
    def tools
      raise NotImplementedError, "#{self.class}#tools must return Hash[String, Callable]"
    end

    def start
      # Optional — can be lazy-initialized in execute
    end

    def execute(code, variables: {})
      raise NotImplementedError, "#{self.class}#execute must return String or FinalOutput"
    end

    def shutdown
      # Optional cleanup
    end
  end
end
