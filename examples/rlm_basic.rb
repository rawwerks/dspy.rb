#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic DSPy::RLM example — Code Interpreter for QA
#
# Usage:
#   DSPY_WITH_OPENAI=1 bundle install
#   OPENAI_API_KEY=sk-... ruby examples/rlm_basic.rb

require 'dspy'

# Configure the LM
DSPy.configure do |c|
  c.lm = DSPy::LM.new(
    ENV.fetch('DSPY_LM', 'openai/gpt-4o-mini'),
    api_key: ENV['OPENAI_API_KEY']
  )
end

# Define a signature: given a context, extract an answer
class ContextQA < DSPy::Signature
  description "Answer a question by writing Ruby code to analyze the context."

  input do
    const :context, String, description: "Text passage to analyze"
    const :question, String, description: "Question to answer"
  end

  output do
    const :answer, String, description: "The answer to the question"
  end
end

# Create an RLM instance — it will use Ruby REPL to explore the context
rlm = DSPy::RLM.new(
  ContextQA,
  max_iterations: 10,
  max_llm_calls: 5,
  verbose: true
)

# Example: extract information from a passage
context = <<~TEXT
  The Ruby programming language was created by Yukihiro "Matz" Matsumoto.
  It was first released in 1995. Ruby is known for its elegant syntax and
  was influenced by Perl, Smalltalk, Eiffel, Ada, and Lisp. The latest
  stable version as of 2024 is Ruby 3.3. Ruby on Rails, the popular web
  framework, was created by David Heinemeier Hansson in 2004.
TEXT

result = rlm.call(context: context, question: "Who created Ruby and when was it first released?")

puts "\n=== Result ==="
puts "Answer: #{result.answer}"
puts "Iterations: #{rlm.iteration_count}"
