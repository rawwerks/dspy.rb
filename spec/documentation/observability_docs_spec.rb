# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Observability Documentation' do
  let(:doc_path) { File.expand_path('../../docs/src/production/observability.md', __dir__) }
  let(:content) { File.read(doc_path) }

  it 'documents telemetry environment variables and tuning guidance' do
    expect(content).to include('DSPY_DISABLE_OBSERVABILITY')
    expect(content).to include('DSPY_TELEMETRY_QUEUE_SIZE')
    expect(content).to include('DSPY_TELEMETRY_EXPORT_INTERVAL')
    expect(content).to include('DSPY_TELEMETRY_BATCH_SIZE')
    expect(content).to include('DSPY_TELEMETRY_SHUTDOWN_TIMEOUT')
    expect(content).to include('CLI / short-lived process')
    expect(content).to include('Web API')
    expect(content).to include('Background jobs')
    expect(content).to include('Development / local')
  end
end
