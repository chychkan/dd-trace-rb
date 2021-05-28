require 'concurrent-ruby' # concurrent-ruby is not modular

require 'ddtrace/contrib/support/spec_helper'
require 'ddtrace'
require 'spec/support/thread_helpers'

RSpec.describe 'ConcurrentRuby integration tests' do
  let(:configuration_options) { {} }
  let(:outer_span) { spans.find { |s| s.name == 'outer_span' } }
  let(:inner_span) { spans.find { |s| s.name == 'inner_span' } }

  before do
    # stub inheritance chain for instrumentation rollback
    stub_const('Concurrent::Promises', ::Concurrent::Promises.dup)
    stub_const('Concurrent::Future', ::Concurrent::Future.dup)
  end

  after do
    remove_patch!(:concurrent_ruby)
  end

  shared_examples_for 'deferred execution' do
    before do
      deferred_execution
    end

    it 'creates outer span with nil parent' do
      expect(outer_span.parent).to be_nil
    end

    it 'writes inner span to tracer' do
      expect(spans).to include(inner_span)
    end

    it 'writes outer span to tracer' do
      expect(spans).to include(outer_span)
    end
  end

  context 'Concurrent::Promises::Future' do
    before(:context) do
      # Execute an async future to force the eager creation of internal
      # global threads that are never closed.
      #
      # This allows us to separate internal concurrent-ruby threads
      # from ddtrace threads for leak detection.
      ThreadHelpers.with_leaky_thread_creation(:concurrent_ruby) do
        Concurrent::Promises.future {}.value
      end
    end

    subject(:deferred_execution) do
      outer_span = tracer.trace('outer_span')
      future = Concurrent::Promises.future do
        tracer.trace('inner_span') {}
      end

      future.wait
      outer_span.finish
    end

    describe 'patching' do
      subject(:patch) do
        Datadog.configure do |c|
          c.use :concurrent_ruby
        end
      end

      it 'adds PromisesFuturePatch to Promises ancestors' do
        expect { patch }.to change { ::Concurrent::Promises.singleton_class.ancestors.map(&:to_s) }
          .to include('Datadog::Contrib::ConcurrentRuby::PromisesFuturePatch')
      end
    end

    context 'when context propagation is disabled' do
      it_behaves_like 'deferred execution'

      it 'inner span should not have parent' do
        deferred_execution
        expect(inner_span.parent).to be_nil
      end
    end

    context 'when context propagation is enabled' do
      before do
        Datadog.configure do |c|
          c.use :concurrent_ruby
        end
      end

      it_behaves_like 'deferred execution'

      it 'inner span parent should be included in outer span' do
        deferred_execution
        expect(inner_span.parent).to eq(outer_span)
      end
    end
  end

  context 'Concurrent::Future (deprecated)' do
    before(:context) do
      # Execute an async future to force the eager creation of internal
      # global threads that are never closed.
      #
      # This allows us to separate internal concurrent-ruby threads
      # from ddtrace threads for leak detection.
      ThreadHelpers.with_leaky_thread_creation(:concurrent_ruby) do
        Concurrent::Future.execute {}.value
      end
    end

    subject(:deferred_execution) do
      outer_span = tracer.trace('outer_span')
      future = Concurrent::Future.new do
        tracer.trace('inner_span') {}
      end
      future.execute

      future.wait
      outer_span.finish
    end

    describe 'patching' do
      subject(:patch) do
        Datadog.configure do |c|
          c.use :concurrent_ruby
        end
      end

      it 'adds FuturePatch to Future ancestors' do
        expect { patch }.to change { ::Concurrent::Future.ancestors.map(&:to_s) }
          .to include('Datadog::Contrib::ConcurrentRuby::FuturePatch')
      end
    end

    context 'when context propagation is disabled' do
      it_behaves_like 'deferred execution'

      it 'inner span should not have parent' do
        deferred_execution
        expect(inner_span.parent).to be_nil
      end
    end

    context 'when context propagation is enabled' do
      before do
        Datadog.configure do |c|
          c.use :concurrent_ruby
        end
      end

      it_behaves_like 'deferred execution'

      it 'inner span parent should be included in outer span' do
        deferred_execution
        expect(inner_span.parent).to eq(outer_span)
      end
    end
  end
end
