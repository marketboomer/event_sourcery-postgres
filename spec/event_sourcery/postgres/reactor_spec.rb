RSpec.describe EventSourcery::Postgres::Reactor do
  TermsConfirmationEmailSent = Class.new(EventSourcery::Event)
  ItemViewed = Class.new(EventSourcery::Event)
  EchoEvent = Class.new(EventSourcery::Event)

  let(:reactor_class) do
    Class.new do
      include EventSourcery::Postgres::Reactor

      process TermsAccepted do |event|
        @processed_event = event
      end

      attr_reader :processed_event
    end
  end
  let(:reactor_class_with_emit) do
    Class.new do
      include EventSourcery::Postgres::Reactor

      emits_events TermsConfirmationEmailSent

      process TermsAccepted do |event|
      end
    end
  end

  let(:tracker) { EventSourcery::Memory::Tracker.new }
  let(:reactor_name) { 'my_reactor' }
  let(:event_store) { EventSourcery::Memory::EventStore.new(events) }
  let(:event_source) { EventSourcery::EventStore::EventSource.new(event_store) }

  let(:event_sink) { EventSourcery::EventStore::EventSink.new(event_store) }
  let(:aggregate_id) { SecureRandom.uuid }
  let(:events) { [] }
  subject(:reactor) { reactor_class.new(tracker: tracker, event_source: event_source, event_sink: event_sink) }

  describe '.new' do
    let(:event_source) { double }
    let(:event_sink) { double }
    let(:projections_database) { double }
    let(:event_tracker) { double }

    before do
      allow(EventSourcery::Postgres::Tracker).to receive(:new).with(projections_database).and_return(event_tracker)
      allow(projections_database).to receive(:extension).with(:pg_json)

      EventSourcery::Postgres.configure do |config|
        config.event_source = event_source
        config.event_sink = event_sink
        config.projections_database = projections_database
      end
    end

    subject(:reactor) { reactor_class.new }

    it 'uses the configured projections database by default' do
      expect(reactor.instance_variable_get('@db_connection')).to eq projections_database
    end

    it 'uses the inferred event tracker database by default' do
      expect(reactor.instance_variable_get('@tracker')).to eq event_tracker
    end

    it 'uses the configured event source by default' do
      expect(reactor.instance_variable_get('@event_source')).to eq event_source
    end

    it 'uses the configured event sink by default' do
      expect(reactor.instance_variable_get('@event_sink')).to eq event_sink
    end
  end

  context "a processor that doesn't emit events" do
    it "doesn't require an event sink" do
      expect {
        reactor_class.new(tracker: tracker, event_source: event_source)
      }.to_not raise_error
    end

    it "doesn't require an event source" do
      expect {
        reactor_class.new(tracker: tracker, event_sink: event_sink)
      }.to_not raise_error
      expect { reactor.setup }.to_not raise_error
    end
  end

  context 'a processor that does emit events' do
    it 'requires an event sink' do
      expect {
        reactor_class_with_emit.new(tracker, event_source, nil)
      }.to raise_error(ArgumentError)
    end

    it 'requires an event source' do
      expect {
        reactor_class_with_emit.new(tracker, nil, event_sink)
      }.to raise_error(ArgumentError)
    end
  end

  describe '#setup' do
    it 'sets up the tracker to ensure we have a track entry' do
      expect(tracker).to receive(:setup).with(reactor_class.processor_name)
      reactor.setup
    end
  end

  describe '#reset' do
    it 'resets last processed event ID' do
      reactor.process(TermsAccepted.new(id: 1))
      reactor.reset
      expect(tracker.last_processed_event_id(:test_processor)).to eq 0
    end
  end

  describe '.processes?' do
    it 'returns true if the event has been defined' do
      expect(reactor_class.processes?('terms_accepted')).to eq true
      expect(reactor_class.processes?(:terms_accepted)).to eq true
    end

    it "returns false if the event hasn't been defined" do
      expect(reactor_class.processes?('item_viewed')).to eq false
      expect(reactor_class.processes?(:item_viewed)).to eq false
    end
  end

  describe '.emits_event?' do
    it 'returns true if the event has been defined' do
      expect(reactor_class_with_emit.emits_event?(TermsConfirmationEmailSent)).to eq true
    end

    it "returns false if the event hasn't been defined" do
      expect(reactor_class_with_emit.emits_event?(ItemViewed)).to eq false
    end

    it "returns false if the reactor doesn't emit events" do
      expect(reactor_class.emits_event?(TermsConfirmationEmailSent)).to eq false
    end
  end

  describe '#process' do
    let(:event) { TermsAccepted.new(id: 1) }

    it "projects events it's interested in" do
      reactor.process(event)
      expect(reactor.processed_event).to eq(event)
    end

    context 'with a reactor that emits events' do
      let(:event_1) do
        TermsAccepted.new(
          id: 1,
          aggregate_id: aggregate_id,
          body: { time: Time.now },
          correlation_id: SecureRandom.uuid,
        )
      end
      let(:event_2) do
        EchoEvent.new(
          id: 2,
          aggregate_id: aggregate_id,
          body: event_1.body,
          correlation_id: event_1.correlation_id,
          causation_id: event_1.uuid,
        )
      end
      let(:event_3) { TermsAccepted.new(id: 3, aggregate_id: aggregate_id, body: { time: Time.now }) }
      let(:event_4) { TermsAccepted.new(id: 4, aggregate_id: aggregate_id, body: { time: Time.now }) }
      let(:event_5) { TermsAccepted.new(id: 5, aggregate_id: aggregate_id, body: { time: Time.now }) }
      let(:event_6) { EchoEvent.new(id: 6, aggregate_id: aggregate_id, body: event_3.body, causation_id: event_3.uuid) }
      let(:events) { [event_1, event_2, event_3, event_4] }
      let(:action_stub_class) do
        Class.new do
          def self.action(id)
            actioned << id
          end

          def self.actioned
            @actions ||= []
          end
        end
      end
      let(:reactor_class) do
        Class.new do
          include EventSourcery::Postgres::Reactor

          emits_events EchoEvent

          process TermsAccepted do |event|
            @event = event
            emit_event(EchoEvent.new(aggregate_id: event.aggregate_id, body: event.body)) do
              TestActioner.action(event.id)
            end
          end

          attr_reader :event
        end
      end

      before do
        reactor.setup
        stub_const('TestActioner', action_stub_class)
      end

      def event_count
        event_source.get_next_from(0, limit: 100).count
      end

      def latest_events(n = 1)
        event_source.get_next_from(0, limit: 100)[-n..-1]
      end

      context "when the event emitted doesn't take actions" do
        let(:reactor_class) do
          Class.new do
            include EventSourcery::Postgres::Reactor

            emits_events EchoEvent

            process TermsAccepted do |event|
              emit_event(EchoEvent.new(aggregate_id: event.aggregate_id, body: event.body))
            end
          end
        end

        it 'processes the events as usual' do
          [event_1, event_2, event_3, event_4, event_5].each do |event|
            reactor.process(event)
          end
          expect(event_count).to eq 8
        end

        it 'stores the event causation id' do
          reactor.process(event_1)
          expect(latest_events(1).first.causation_id).to eq event_1.uuid
        end

        it 'stores the event correlation id' do
          reactor.process(event_1)
          expect(latest_events(1).first.correlation_id).to eq event_1.correlation_id
        end
      end

      context "when the event emitted hasn't been defined in emit_events" do
        let(:reactor_class) do
          Class.new do
            include EventSourcery::Postgres::Reactor

            emits_events EchoEvent

            process TermsAccepted do |event|
              emit_event(ItemViewed.new(aggregate_id: event.aggregate_id, body: event.body))
            end
          end
        end

        it 'raises an error' do
          expect {
            reactor.process(event_1)
          }.to raise_error(EventSourcery::EventProcessingError)
        end
      end

      context 'when body is yielded to the emit block' do
        let(:events) { [] }
        let(:reactor_class) do
          Class.new do
            include EventSourcery::Postgres::Reactor

            emits_events EchoEvent

            process TermsAccepted do |event|
              emit_event(EchoEvent.new(aggregate_id: event.aggregate_id)) do |body|
                body[:token] = 'secret-identifier'
              end
            end
          end
        end

        it 'can manupulate the event body as part of the action' do
          reactor.process(event_1)
          expect(latest_events(1).first.body['token']).to eq 'secret-identifier'
        end

        it 'stores the event causation id' do
          reactor.process(event_1)
          expect(latest_events(1).first.causation_id).to eq event_1.uuid
        end

        it 'stores the event correlation id' do
          reactor.process(event_1)
          expect(latest_events(1).first.correlation_id).to eq event_1.correlation_id
        end
      end
    end
  end
end
