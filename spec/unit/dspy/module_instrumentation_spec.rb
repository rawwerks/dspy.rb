# frozen_string_literal: true

require 'spec_helper'
require 'dspy/re_act'

class ModuleInstrumentationSpecSignature < DSPy::Signature
  description 'Predict instrumentation test signature'

  input do
    const :question, String
  end

  output do
    const :answer, String
  end
end

RSpec.describe DSPy::Module do
  describe '#instrument_forward_call' do
    before do
      DSPy.configure { |config| config.lm = nil }
    end

    it 'adds signature identity to predict spans' do
      captured = {}
      predictor = DSPy::Predict.new(ModuleInstrumentationSpecSignature)

      allow(DSPy::Context).to receive(:with_module).and_yield
      allow(DSPy::Context).to receive(:with_span) do |operation:, **attrs, &block|
        captured[:operation] = operation
        captured[:attrs] = attrs
        block.call(nil)
      end

      predictor.send(:instrument_forward_call, [], { question: 'hi' }) { 'ok' }

      expect(captured[:operation]).to eq("DSPy::Predict(#{ModuleInstrumentationSpecSignature.name}).forward")
      expect(captured[:attrs]).to include('dspy.signature' => ModuleInstrumentationSpecSignature.name)
      expect(captured[:attrs]).to include('dspy.signature_kind' => 'custom')
    end

    it 'keeps non-predict module operation naming unchanged' do
      test_module_class = Class.new(DSPy::Module) do
        def forward_untyped(**_kwargs)
          :ok
        end
      end

      captured = {}
      instance = test_module_class.new

      allow(DSPy::Context).to receive(:with_module).and_yield
      allow(DSPy::Context).to receive(:with_span) do |operation:, **attrs, &block|
        captured[:operation] = operation
        captured[:attrs] = attrs
        block.call(nil)
      end

      instance.send(:instrument_forward_call, [], {}) { :ok }

      expect(captured[:operation]).to eq("#{test_module_class.name}.forward")
      expect(captured[:attrs]).not_to have_key('dspy.signature')
      expect(captured[:attrs]).not_to have_key('dspy.signature_kind')
    end

    it 'adds conversation_id to root trace init from kwargs when present' do
      captured_spans = []
      predictor = DSPy::Predict.new(ModuleInstrumentationSpecSignature)

      allow(DSPy::Context).to receive(:with_module).and_yield
      allow(DSPy::Context).to receive(:with_span) do |operation:, **attrs, &block|
        captured_spans << { operation: operation, attrs: attrs }
        block.call(nil)
      end

      predictor.send(:instrument_forward_call, [], { question: 'hi', conversation_id: 'conv-123' }) { 'ok' }

      trace_init = captured_spans.find { |span| span[:operation] == 'dspy.trace.init' }
      expect(trace_init).not_to be_nil
      expect(trace_init[:attrs]).to include('conversation_id' => 'conv-123')
      expect(trace_init[:attrs]).to include('dspy.conversation_id' => 'conv-123')

      metadata = JSON.parse(trace_init[:attrs]['langfuse.trace.metadata'])
      expect(metadata['conversation_id_source']).to eq('kwargs.conversation_id')
    end

    it 'falls back to context conversation_id when kwargs do not include one' do
      captured_spans = []
      predictor = DSPy::Predict.new(ModuleInstrumentationSpecSignature)

      allow(DSPy::Context).to receive(:with_module).and_yield
      allow(DSPy::Context).to receive(:with_span) do |operation:, **attrs, &block|
        captured_spans << { operation: operation, attrs: attrs }
        block.call(nil)
      end

      DSPy::Context.current[:conversation_id] = 'ctx-987'

      predictor.send(:instrument_forward_call, [], { question: 'hi' }) { 'ok' }

      trace_init = captured_spans.find { |span| span[:operation] == 'dspy.trace.init' }
      expect(trace_init).not_to be_nil
      expect(trace_init[:attrs]).to include('conversation_id' => 'ctx-987')

      metadata = JSON.parse(trace_init[:attrs]['langfuse.trace.metadata'])
      expect(metadata['conversation_id_source']).to eq('context.conversation_id')
    end

    it 'serializes react max-iterations error details into trace output payload' do
      predictor = DSPy::Predict.new(ModuleInstrumentationSpecSignature)
      error = DSPy::ReAct::MaxIterationsError.new(
        'max iterations',
        iterations: 1,
        max_iterations: 1,
        tools_used: ['noop_obs'],
        history: [],
        last_observation: nil,
        partial_final_answer: nil
      )

      payload = predictor.send(:serialize_module_error_output, error)
      parsed = JSON.parse(payload)

      expect(parsed.dig('react', 'iterations')).to eq(1)
      expect(parsed.dig('react', 'max_iterations')).to eq(1)
      expect(parsed.dig('react', 'tools_used')).to eq(['noop_obs'])
    end
  end
end
