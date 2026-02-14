# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Pre-load gems RSpec uses lazily — sandbox require pollution workaround
require 'pp'
require 'ripper'
require 'stringio'

require 'dspy'

# ---------------------------------------------------------------------------
# Test signatures
# ---------------------------------------------------------------------------

class RLMTestSig < DSPy::Signature
  description 'Analyze input text'
  input { const :context, String, description: 'input text' }
  output { const :answer, String, description: 'the answer' }
end

class RLMMultiOutputSig < DSPy::Signature
  description 'Multi-output task'
  input { const :text, String, description: 'source text' }
  output do
    const :summary, String, description: 'a summary'
    const :score, Integer, description: 'quality score'
  end
end

# ---------------------------------------------------------------------------
# 1–4. Constructor, build_variables, action/extract signatures
# ---------------------------------------------------------------------------

RSpec.describe DSPy::RLM do
  let(:rlm) { described_class.new(RLMTestSig, max_iterations: 5) }

  # --- 1. Constructor ---

  describe '#initialize' do
    it 'builds generate_action as a Predict module' do
      expect(rlm.generate_action).to be_a(DSPy::Predict)
    end

    it 'builds extract as a Predict module' do
      expect(rlm.extract).to be_a(DSPy::Predict)
    end

    it 'exposes both via named_predictors' do
      names = rlm.named_predictors.map(&:first)
      expect(names).to contain_exactly('generate_action', 'extract')
    end
  end

  # --- 2. build_variables ---

  describe '#build_variables (private)' do
    it 'creates REPLVariable for each input argument' do
      vars = rlm.send(:build_variables, context: 'hello world')
      expect(vars.length).to eq(1)
      v = vars.first
      expect(v).to be_a(DSPy::REPLVariable)
      expect(v.name).to eq('context')
      expect(v.type_name).to eq('String')
    end

    it 'populates description from the signature field_info' do
      vars = rlm.send(:build_variables, context: 'test')
      expect(vars.first.desc).to eq('input text')
    end

    it 'builds one variable per input field' do
      rlm_multi = described_class.new(RLMMultiOutputSig)
      vars = rlm_multi.send(:build_variables, text: 'some text')
      expect(vars.length).to eq(1)
      expect(vars.first.name).to eq('text')
    end
  end

  # --- 3. Action signature ---

  describe 'action signature' do
    let(:action_sig) { rlm.generate_action.signature_class }

    it 'has variables_info, repl_history, iteration as inputs' do
      keys = action_sig.input_field_descriptors.keys
      expect(keys).to contain_exactly(:variables_info, :repl_history, :iteration)
    end

    it 'has reasoning and code as outputs' do
      keys = action_sig.output_field_descriptors.keys
      expect(keys).to contain_exactly(:reasoning, :code)
    end

    it 'has name RLM::ActionSignature' do
      expect(action_sig.name).to eq('RLM::ActionSignature')
    end
  end

  # --- 4. Extract signature ---

  describe 'extract signature' do
    let(:extract_sig) { rlm.extract.signature_class }

    it 'has variables_info and repl_history as inputs' do
      keys = extract_sig.input_field_descriptors.keys
      expect(keys).to contain_exactly(:variables_info, :repl_history)
    end

    it 'has user output fields in its output struct' do
      struct_keys = extract_sig.output_struct_class.props.keys
      expect(struct_keys).to include(:answer)
    end

    it 'has name RLM::ExtractSignature' do
      expect(extract_sig.name).to eq('RLM::ExtractSignature')
    end

    context 'with multi-output signature' do
      let(:rlm_multi) { described_class.new(RLMMultiOutputSig) }
      let(:extract_sig) { rlm_multi.extract.signature_class }

      it 'includes all user output fields' do
        struct_keys = extract_sig.output_struct_class.props.keys
        expect(struct_keys).to contain_exactly(:summary, :score)
      end
    end
  end

  # --- 5. Instructions.build_action_instructions ---

  describe DSPy::RLM::Instructions, '.build_action_instructions' do
    let(:instructions) do
      described_class.build_action_instructions(RLMTestSig, max_llm_calls: 10)
    end

    it 'includes the task description' do
      expect(instructions).to include('Analyze input text')
    end

    it 'includes the input field name' do
      expect(instructions).to include('`context`')
    end

    it 'includes the output field name and type' do
      expect(instructions).to include('answer')
      expect(instructions).to include('String')
    end

    it 'includes SUBMIT directive' do
      expect(instructions).to include('SUBMIT')
    end

    it 'includes max LLM calls' do
      expect(instructions).to include('10')
    end

    it 'includes tool docs when provided' do
      instr = described_class.build_action_instructions(
        RLMTestSig, max_llm_calls: 5, tool_docs: "- `search(...)` — web search"
      )
      expect(instr).to include('search')
      expect(instr).to include('web search')
    end
  end

  # --- 6. Instructions.build_extract_instructions ---

  describe DSPy::RLM::Instructions, '.build_extract_instructions' do
    let(:instructions) { described_class.build_extract_instructions(RLMTestSig) }

    it 'includes the task description' do
      expect(instructions).to include('Analyze input text')
    end

    it 'mentions trajectory' do
      expect(instructions).to include('trajectory')
    end
  end

  # --- 7. process_final_output — correct types ---

  describe '#process_final_output (private)' do
    it 'returns parsed hash with symbolized keys for valid output' do
      fo = DSPy::FinalOutput.new({ answer: '42' })
      parsed, err = rlm.send(:process_final_output, fo, ['answer'])
      expect(err).to be_nil
      expect(parsed).to eq({ answer: '42' })
    end

    it 'coerces String to Integer when output type is Integer' do
      rlm_int = described_class.new(RLMMultiOutputSig)
      fo = DSPy::FinalOutput.new({ summary: 'good', score: '8' })
      parsed, err = rlm_int.send(:process_final_output, fo, %w[summary score])
      expect(err).to be_nil
      expect(parsed[:score]).to eq(8)
      expect(parsed[:score]).to be_a(Integer)
    end

    it 'handles string keys in the output hash' do
      fo = DSPy::FinalOutput.new({ 'answer' => 'yes' })
      parsed, err = rlm.send(:process_final_output, fo, ['answer'])
      expect(err).to be_nil
      expect(parsed[:answer]).to eq('yes')
    end

    # --- 8. process_final_output — rejects missing fields ---

    it 'returns error string when fields are missing' do
      fo = DSPy::FinalOutput.new({ wrong_field: 'oops' })
      parsed, err = rlm.send(:process_final_output, fo, ['answer'])
      expect(parsed).to be_nil
      expect(err).to include('Missing fields')
      expect(err).to include('answer')
    end

    it 'returns error when output is not a Hash' do
      fo = DSPy::FinalOutput.new('just a string')
      parsed, err = rlm.send(:process_final_output, fo, ['answer'])
      expect(parsed).to be_nil
      expect(err).to include('expected keyword arguments')
    end

    it 'returns error when output is an Array' do
      fo = DSPy::FinalOutput.new([1, 2, 3])
      parsed, err = rlm.send(:process_final_output, fo, ['answer'])
      expect(parsed).to be_nil
      expect(err).to include('expected keyword arguments')
    end
  end

  # --- 9. normalize_tools ---

  describe '#normalize_tools (private)' do
    it 'passes through a Hash unchanged' do
      tool_fn = lambda { |q| q }
      result = rlm.send(:normalize_tools, { 'search' => tool_fn })
      expect(result).to eq({ 'search' => tool_fn })
    end

    it 'converts an Array of tool objects to Hash keyed by tool_name' do
      tool = Class.new do
        def self.tool_name; 'my_tool'; end
        def self.call(*args); 'result'; end
      end
      result = rlm.send(:normalize_tools, [tool])
      expect(result.keys).to eq(['my_tool'])
    end

    it 'returns empty hash for empty Array' do
      expect(rlm.send(:normalize_tools, [])).to eq({})
    end

    it 'returns empty hash for nil' do
      expect(rlm.send(:normalize_tools, nil)).to eq({})
    end

    it 'returns empty hash for unexpected types' do
      expect(rlm.send(:normalize_tools, 42)).to eq({})
    end
  end

  # --- 10. format_tool_docs ---

  describe '#format_tool_docs (private)' do
    it 'returns empty string when no user tools' do
      expect(rlm.send(:format_tool_docs)).to eq('')
    end

    it 'lists each user tool' do
      rlm_tools = described_class.new(
        RLMTestSig,
        tools: { 'search' => lambda { |q| q }, 'fetch' => lambda { |u| u } }
      )
      docs = rlm_tools.send(:format_tool_docs)
      expect(docs).to include('`search(...)`')
      expect(docs).to include('`fetch(...)`')
      expect(docs).to include('user-provided tool')
    end
  end
end
