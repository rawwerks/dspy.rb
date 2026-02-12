# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DSPy::Context do
  before do
    described_class.clear!
  end

  after do
    described_class.clear!
  end

  it 'uses current OpenTelemetry span as parent when local otel stack is empty' do
    parent_span = instance_double(OpenTelemetry::Trace::Span)
    span = instance_double('Span', set_attribute: nil)
    tracer = double('Tracer')

    allow(DSPy::Observability).to receive(:enabled?).and_return(true)
    allow(DSPy::Observability).to receive(:tracer).and_return(tracer)
    allow(OpenTelemetry::Trace).to receive(:current_span).and_return(parent_span)
    allow(OpenTelemetry::Trace).to receive(:with_span).with(parent_span).and_yield
    allow(tracer).to receive(:in_span).and_yield(span)

    described_class.with_span(operation: 'worker.operation') { :ok }

    expect(OpenTelemetry::Trace).to have_received(:with_span).with(parent_span)
  end

  it 'does not wrap span creation when current OpenTelemetry span is invalid' do
    span = instance_double('Span', set_attribute: nil)
    tracer = double('Tracer')

    allow(DSPy::Observability).to receive(:enabled?).and_return(true)
    allow(DSPy::Observability).to receive(:tracer).and_return(tracer)
    allow(OpenTelemetry::Trace).to receive(:current_span).and_return(OpenTelemetry::Trace::Span::INVALID)
    allow(OpenTelemetry::Trace).to receive(:with_span).and_call_original
    allow(tracer).to receive(:in_span).and_yield(span)

    described_class.with_span(operation: 'root.operation') { :ok }

    expect(OpenTelemetry::Trace).not_to have_received(:with_span)
  end
end
