# frozen_string_literal: true

# These tests run DSPy::RLM against a REAL LLM on REAL tasks.
# They are the primary test suite — not mocks.
#
# Run: OPENROUTER_API_KEY=... rspec spec/dspy/rlm_dogfood_spec.rb
#
# If these tests don't exist or don't pass, the module is not tested.
# See: 112 mock tests caught 0 bugs. 1 dogfood session found 13.

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'dspy'

RSpec.describe "DSPy::RLM dogfood" do
  before(:all) do
    skip "Set OPENROUTER_API_KEY to run dogfood tests" unless ENV['OPENROUTER_API_KEY']
    DSPy.configure do |c|
      c.lm = DSPy::LM.new('openrouter/google/gemini-2.0-flash-001', api_key: ENV['OPENROUTER_API_KEY'])
    end
  end

  class FactQA < DSPy::Signature
    description "Answer a question by writing Ruby code to analyze the context."
    input do
      const :context, String, description: "Text to analyze"
      const :question, String, description: "Question to answer"
    end
    output do
      const :answer, String, description: "The answer"
    end
  end

  class PersonExtract < DSPy::Signature
    description "Extract person details from text using Ruby code."
    input do
      const :text, String, description: "Text about a person"
    end
    output do
      const :name, String, description: "Person's full name"
      const :age, String, description: "Person's age"
      const :city, String, description: "City they live in"
    end
  end

  class RepoAnalysis < DSPy::Signature
    description "Analyze a Ruby codebase using the provided file tools."
    input do
      const :question, String, description: "Question about the codebase"
    end
    output do
      const :answer, String, description: "Detailed answer"
    end
  end

  it "extracts a fact with SUBMIT" do
    rlm = DSPy::RLM.new(FactQA, max_iterations: 10)
    result = rlm.call(
      context: "Ada Lovelace wrote the first computer program in 1843.",
      question: "What year did Ada Lovelace write the first program?"
    )
    expect(result.answer.to_s).to include("1843")
    expect(rlm.iteration_count).to be <= 10
  end

  it "computes from data" do
    rlm = DSPy::RLM.new(FactQA, max_iterations: 10)
    result = rlm.call(
      context: "Prices: apple $1.50, banana $0.75, cherry $3.00",
      question: "What is the total price of all items?"
    )
    expect(result.answer.to_s.gsub(/[$,]/, '')).to match(/5\.?25/)
  end

  it "extracts multiple fields" do
    rlm = DSPy::RLM.new(PersonExtract, max_iterations: 10)
    result = rlm.call(text: "Maria Garcia is 28 years old and lives in Barcelona, Spain.")
    expect(result.name).to include("Maria")
    expect(result.age.to_s).to include("28")
    expect(result.city.downcase).to include("barcelona")
  end

  it "uses llm_query from the sandbox" do
    rlm = DSPy::RLM.new(FactQA, max_iterations: 12, max_llm_calls: 3)
    result = rlm.call(
      context: "The product is amazing but shipping took forever.",
      question: "Use llm_query to classify the sentiment. Answer: positive, negative, or mixed."
    )
    expect(%w[positive negative mixed]).to include(result.answer.downcase.strip)
  end

  it "uses FileTools to analyze this repo" do
    file_tools = DSPy::RLM::FileTools.new(File.expand_path('../..', __dir__))
    rlm = DSPy::RLM.new(RepoAnalysis, max_iterations: 10, tools: file_tools.to_tools)
    result = rlm.call(question: "How many .rb files are in the lib/dspy directory (non-recursive)?")
    count = result.answer.to_s.scan(/\d+/).map(&:to_i).max
    actual = Dir.glob(File.expand_path('../../lib/dspy/*.rb', __dir__)).count
    # Within 5 of actual — model might count slightly differently
    expect(count).to be_within(5).of(actual)
  end

  it "handles unicode" do
    rlm = DSPy::RLM.new(FactQA, max_iterations: 8)
    result = rlm.call(
      context: "Le café coûte 4,50€. Der Kaffee kostet 4,50€. コーヒーは450円です。",
      question: "How much does coffee cost in euros?"
    )
    expect(result.answer.to_s).to match(/4[.,]50/)
  end
end
