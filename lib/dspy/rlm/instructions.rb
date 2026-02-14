# frozen_string_literal: true

module DSPy
  class RLM
    module Instructions
      ACTION_TEMPLATE = <<~PROMPT
        %{task_instructions}

        You are tasked with producing the following outputs given the inputs %{inputs}:
        %{output_fields}

        You have access to a Ruby REPL environment. Write Ruby code and it will be executed.
        You will see the output, then write more code based on what you learned.
        This is an iterative process.

        Available:
        - Variables: %{inputs} (your input data — access them directly in code)
        - `llm_query(prompt)` — query a sub-LLM for semantic analysis
        - `puts` / `print` / `p` — ALWAYS print to see results
        - `SUBMIT(%{final_output_names})` — submit final output when done
        - Standard library: JSON, Set, Date, Time, Regexp, etc.
        %{tool_docs}

        IMPORTANT: This is ITERATIVE. Each code block executes, you see the output,
        then you decide what to do next. Do NOT try to solve everything in one step.

        1. EXPLORE FIRST — Look at your data before processing it.
        2. ITERATE — Write small snippets, observe outputs, then decide next steps.
        3. USE llm_query FOR SEMANTICS — Ruby finds WHERE things are; llm_query understands WHAT they mean.
        4. SUBMIT WHEN READY — SUBMIT ends the run immediately.

        You have max %{max_llm_calls} sub-LLM calls.
      PROMPT

      EXTRACT_TEMPLATE = <<~PROMPT
        Based on the REPL trajectory below, extract the final outputs.
        Review the trajectory to see what was gathered and computed.

        %{task_instructions}
      PROMPT

      def self.build_action_instructions(signature_class, max_llm_calls:, tool_docs: "")
        input_names = signature_class.input_field_descriptors.keys.map { |n| "`#{n}`" }.join(", ")
        output_names = signature_class.output_field_descriptors.keys.join(", ")
        output_fields_desc = signature_class.output_field_descriptors.map { |name, fd|
          "- #{name}: #{fd.type} — #{fd.description || '(no description)'}"
        }.join("\n")

        tool_section = tool_docs.empty? ? "" : "\nAdditional tools:\n#{tool_docs}"

        ACTION_TEMPLATE % {
          task_instructions: signature_class.description || "",
          inputs: input_names,
          output_fields: output_fields_desc,
          final_output_names: output_names,
          max_llm_calls: max_llm_calls,
          tool_docs: tool_section
        }
      end

      def self.build_extract_instructions(signature_class)
        EXTRACT_TEMPLATE % {
          task_instructions: signature_class.description || ""
        }
      end
    end
  end
end
