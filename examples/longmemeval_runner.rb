#!/usr/bin/env ruby
# frozen_string_literal: true

# LongMemEval benchmark runner for DSPy::RLM
#
# Runs RLM against the LongMemEval QA dataset, where the model must
# write Ruby code to search through conversation haystacks and answer questions.
#
# Usage:
#   # Smoke test (first 5 questions):
#   ruby examples/longmemeval_runner.rb --data data/sample.json --limit 5
#
#   # Full 64-question subset:
#   ruby examples/longmemeval_runner.rb --data path/to/longmemeval.json --limit 64
#
#   # Resume from previous run:
#   ruby examples/longmemeval_runner.rb --data data.json --output results.jsonl --resume

require 'json'
require 'optparse'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'dspy'

# --- Signature ---
class LongMemEvalQA < DSPy::Signature
  description "Answer a question about a user's conversation history by writing Ruby code to search and analyze the haystack sessions."

  input do
    const :context, String, description: "Conversation sessions (the haystack) — a long text with multiple dated sessions"
    const :question, String, description: "Question about the user's history"
  end

  output do
    const :answer, String, description: "Short factual answer to the question"
  end
end

# --- CLI ---
options = {
  limit: 5,
  output: 'longmemeval_results.jsonl',
  resume: false,
  max_iterations: 15,
  max_llm_calls: 20,
  verbose: false,
  model: ENV.fetch('DSPY_LM', 'openai/gpt-4o-mini')
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby examples/longmemeval_runner.rb [options]"
  opts.on("--data FILE", "Path to LongMemEval JSON data file") { |v| options[:data] = v }
  opts.on("--limit N", Integer, "Max questions to run (default: 5)") { |v| options[:limit] = v }
  opts.on("--output FILE", "Output JSONL file (default: longmemeval_results.jsonl)") { |v| options[:output] = v }
  opts.on("--resume", "Skip already-completed question IDs") { options[:resume] = true }
  opts.on("--max-iterations N", Integer, "Max REPL iterations per question") { |v| options[:max_iterations] = v }
  opts.on("--verbose", "Print REPL interactions") { options[:verbose] = true }
  opts.on("--model MODEL", "LM model string (default: openai/gpt-4o-mini)") { |v| options[:model] = v }
end.parse!

abort "Missing --data FILE" unless options[:data]
abort "Data file not found: #{options[:data]}" unless File.exist?(options[:data])

# --- Load data ---
questions = JSON.parse(File.read(options[:data]))
questions = questions.first(options[:limit]) if options[:limit]

# --- Resume support ---
completed_ids = Set.new
if options[:resume] && File.exist?(options[:output])
  File.readlines(options[:output]).each do |line|
    rec = JSON.parse(line) rescue next
    completed_ids << rec['question_id'] if rec['question_id']
  end
  puts "Resuming: #{completed_ids.size} already completed"
end

# --- Configure LM ---
DSPy.configure do |c|
  c.lm = DSPy::LM.new(options[:model], api_key: ENV['OPENAI_API_KEY'])
end

rlm = DSPy::RLM.new(
  LongMemEvalQA,
  max_iterations: options[:max_iterations],
  max_llm_calls: options[:max_llm_calls],
  verbose: options[:verbose]
)

# --- Run ---
correct = 0
total = 0

questions.each_with_index do |q, idx|
  next if completed_ids.include?(q['question_id'])

  # Build context from haystack sessions
  context = (q['haystack_sessions'] || []).map { |s|
    "#{s['date']}\n#{s['content']}"
  }.join("\n\n---\n\n")

  if context.empty?
    puts "[#{idx + 1}] SKIP #{q['question_id']} — no haystack sessions"
    next
  end

  total += 1
  puts "[#{total}/#{questions.size}] #{q['question_id']}: #{q['question']}"

  begin
    result = rlm.call(context: context, question: q['question'])
    predicted = result.answer
  rescue => e
    predicted = "[ERROR] #{e.class}: #{e.message}"
    $stderr.puts "  Error: #{e.message}"
  end

  # Simple exact-match check (case-insensitive, strip whitespace)
  gold = q['answer'].to_s.strip.downcase
  pred = predicted.to_s.strip.downcase
  match = gold == pred || pred.include?(gold) || gold.include?(pred)
  correct += 1 if match

  record = {
    question_id: q['question_id'],
    question_type: q['question_type'],
    question: q['question'],
    gold_answer: q['answer'],
    predicted_answer: predicted,
    match: match,
    iterations: rlm.iteration_count
  }

  File.open(options[:output], 'a') { |f| f.puts(JSON.generate(record)) }
  puts "  Answer: #{predicted} | Gold: #{q['answer']} | #{match ? 'CORRECT' : 'WRONG'}"
end

puts "\n=== Results ==="
puts "Total: #{total}, Correct: #{correct}, Accuracy: #{total > 0 ? (correct.to_f / total * 100).round(1) : 0}%"
