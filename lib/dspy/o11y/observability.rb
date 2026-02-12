# frozen_string_literal: true

require 'json'

module DSPy
  class Observability
    class << self
      attr_reader :tracer, :endpoint

      def register_configurator(name, &block)
        configurators[name.to_sym] = block
      end

      def configure!(adapter: nil)
        reset!

        blocks = if adapter
          block = configurators[adapter.to_sym]
          block ? [block] : []
        else
          configurators.values
        end

        return false if blocks.empty?

        blocks.each do |config|
          begin
            result = config.call(self)
            return true if result || enabled?
          rescue StandardError => e
            DSPy.log('observability.error', error: e.message, adapter: adapter)
          end
        end

        false
      end

      def enabled?
        @enabled == true
      end

      def enable!(tracer:, endpoint: nil)
        @tracer = tracer
        @endpoint = endpoint
        @enabled = true
      end

      def disable!(reason: nil)
        @enabled = false
        @tracer = nil
        @endpoint = nil
        DSPy.log('observability.disabled', reason: reason) if reason
      end

      def start_span(operation_name, attributes = {})
        return nil unless enabled? && tracer

        string_attributes = attributes.transform_keys(&:to_s)
                                     .transform_values { |value| sanitize_attribute_value(value) }
                                     .reject { |_, v| v.nil? }
        string_attributes['operation.name'] = operation_name

        tracer.start_span(
          operation_name,
          kind: :internal,
          attributes: string_attributes
        )
      rescue StandardError => e
        DSPy.log('observability.span_error', error: e.message, operation: operation_name)
        nil
      end

      def finish_span(span)
        return unless span

        span.finish
      rescue StandardError => e
        DSPy.log('observability.span_finish_error', error: e.message)
      end

      def flush!
        return unless enabled?
        return unless defined?(OpenTelemetry) && OpenTelemetry.respond_to?(:tracer_provider)

        OpenTelemetry.tracer_provider.force_flush
      rescue StandardError => e
        DSPy.log('observability.flush_error', error: e.message)
      end

      def reset!
        if defined?(OpenTelemetry) && OpenTelemetry.respond_to?(:tracer_provider) && (provider = OpenTelemetry.tracer_provider)
          begin
            provider.shutdown(timeout: 1.0) if provider.respond_to?(:shutdown)
          rescue StandardError => e
            DSPy.log('observability.shutdown_error', error: e.message)
          end
        end

        @enabled = false
        @tracer = nil
        @endpoint = nil
      end

      def configurators
        @configurators ||= {}
      end

      def require_dependency(lib)
        require lib
      end

      def sanitize_attribute_value(value)
        return value if primitive_value?(value)

        if value.is_a?(Array)
          return value if homogeneous_primitive_array?(value)
          return JSON.generate(value.map { |item| normalize_json_value(item) })
        end

        if value.is_a?(Hash)
          return JSON.generate(normalize_json_value(value))
        end

        if value.respond_to?(:to_h)
          return JSON.generate(normalize_json_value(value.to_h))
        end

        value.respond_to?(:to_json) ? value.to_json : value.to_s
      rescue StandardError
        value.to_s
      end

      def primitive_value?(value)
        value.nil? || value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
      end

      def homogeneous_primitive_array?(value)
        return true if value.empty?
        return false unless value.all? { |item| primitive_value?(item) }

        value.map(&:class).uniq.size == 1
      end

      def normalize_json_value(value)
        if primitive_value?(value)
          value
        elsif value.is_a?(Array)
          value.map { |item| normalize_json_value(item) }
        elsif value.is_a?(Hash)
          value.each_with_object({}) do |(k, v), acc|
            acc[k.to_s] = normalize_json_value(v)
          end
        elsif value.respond_to?(:to_h)
          normalize_json_value(value.to_h)
        else
          value.to_s
        end
      end
    end
  end
end
