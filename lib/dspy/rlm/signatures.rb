# frozen_string_literal: true

require_relative 'instructions'

module DSPy
  class RLM
    module Signatures
      # Build the action signature dynamically from the user's signature.
      # Input: variables_info, repl_history, iteration
      # Output: reasoning, code
      def self.build_action_signature(user_signature, max_llm_calls:, tool_docs: "")
        instructions = Instructions.build_action_instructions(
          user_signature, max_llm_calls: max_llm_calls, tool_docs: tool_docs
        )

        Class.new(DSPy::Signature) do
          description instructions

          input do
            const :variables_info, String,
              description: "Metadata about variables available in the REPL"
            const :repl_history, String,
              description: "Previous REPL interactions"
            const :iteration, String,
              description: "Current iteration N/max"
          end

          output do
            const :reasoning, String,
              description: "Step-by-step plan for next action"
            const :code, String,
              description: "Ruby code to execute in the REPL"
          end

          class << self
            def name
              "RLM::ActionSignature"
            end
          end
        end
      end

      # Build the extract signature dynamically from the user's signature.
      # Input: variables_info, repl_history
      # Output: same as user's output fields
      def self.build_extract_signature(user_signature)
        instructions = Instructions.build_extract_instructions(user_signature)
        output_descriptors = user_signature.output_field_descriptors

        Class.new(DSPy::Signature) do
          description instructions

          input do
            const :variables_info, String,
              description: "Variable metadata"
            const :repl_history, String,
              description: "Full REPL interaction history"
          end

          # Build output matching user's output fields
          output do
            output_descriptors.each do |field_name, fd|
              const field_name.to_sym, fd.type, description: fd.description
            end
          end

          class << self
            def name
              "RLM::ExtractSignature"
            end
          end
        end
      end
    end
  end
end
