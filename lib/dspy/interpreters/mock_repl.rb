# frozen_string_literal: true

require_relative '../code_interpreter'

module DSPy
  module Interpreters
    # Scriptable mock interpreter for testing.
    # Takes a list of responses; returns them sequentially on execute().
    class MockREPL
      include CodeInterpreter

      attr_reader :tools, :executed_code, :call_count

      def initialize(responses: [], tools: {})
        @responses = responses
        @tools = tools
        @call_count = 0
        @executed_code = []
      end

      def execute(code, variables: {})
        @executed_code << code
        response = @responses[@call_count]
        @call_count += 1

        raise CodeInterpreterError, "MockREPL: no response for call #{@call_count}" if response.nil?

        response
      end
    end
  end
end
