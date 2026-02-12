# frozen_string_literal: true

require 'spec_helper'

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
  end
end
