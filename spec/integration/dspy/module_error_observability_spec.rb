# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Module error observability instrumentation' do
  class FailingModuleForObservability < DSPy::Module
    sig { override.params(input_values: T.untyped).returns(T.untyped) }
    def forward_untyped(**input_values)
      raise RuntimeError, "boom"
    end
  end

  let(:mock_span) { double('otel_span') }
  let(:mock_tracer) { double('otel_tracer') }

  before do
    allow(DSPy::Observability).to receive(:enabled?).and_return(true)
    allow(DSPy::Observability).to receive(:tracer).and_return(mock_tracer)
    allow(mock_tracer).to receive(:in_span).and_yield(mock_span)
    allow(mock_span).to receive(:set_attribute)
    DSPy::Context.clear!
  end

  it 'sets output and error attributes on span when module forward raises' do
    expect(mock_span).to receive(:set_attribute).with(
      'langfuse.observation.output',
      include('\"error\"')
    )
    expect(mock_span).to receive(:set_attribute).with('dspy.error.class', 'RuntimeError')
    expect(mock_span).to receive(:set_attribute).with('dspy.error.message', 'boom')

    expect do
      FailingModuleForObservability.new.forward(query: "x")
    end.to raise_error(RuntimeError, 'boom')
  end
end
