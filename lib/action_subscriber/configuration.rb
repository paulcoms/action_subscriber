require 'yaml'
require 'action_subscriber/uri'

module ActionSubscriber
  class Configuration
    attr_accessor :allow_low_priority_methods,
                  :connection_reaping_interval,
                  :connection_reaping_timeout_interval,
                  :decoder,
                  :default_exchange,
                  :error_handler,
                  :heartbeat,
                  :host,
                  :hosts,
                  :network_recovery_interval,
                  :password,
                  :port,
                  :prefetch,
                  :resubscribe_on_consumer_cancellation,
                  :seconds_to_wait_for_graceful_shutdown,
                  :threadpool_size,
                  :timeout,
                  :tls,
                  :tls_ca_certificates,
                  :tls_cert,
                  :tls_key,
                  :username,
                  :verify_peer,
                  :virtual_host

    CONFIGURATION_MUTEX = ::Mutex.new
    NETWORK_RECOVERY_INTERVAL = 1

    DEFAULTS = {
      allow_low_priority_methods: false,
      connection_reaping_interval: 6,
      connection_reaping_timeout_interval: 5,
      default_exchange: 'events',
      heartbeat: 5,
      host: 'localhost',
      hosts: [],
      network_recovery_interval: NETWORK_RECOVERY_INTERVAL,
      password: 'guest',
      port: 5672,
      prefetch: 2,
      resubscribe_on_consumer_cancellation: true,
      seconds_to_wait_for_graceful_shutdown: 30,
      threadpool_size: 8,
      timeout: 1,
      tls: false,
      tls_ca_certificates: [],
      tls_cert: nil,
      tls_key: nil,
      username: 'guest',
      verify_peer: true,
      virtual_host: '/'
    }

    ##
    # Class Methods
    #
    def self.configure_from_yaml_and_cli(cli_options = {}, reload = false)
      CONFIGURATION_MUTEX.synchronize do
        @configure_from_yaml_and_cli = nil if reload
        @configure_from_yaml_and_cli ||= begin
          env = ENV['RAILS_ENV'] || ENV['RACK_ENV'] || ENV['APP_ENV'] || 'development'

          yaml_config = {}
          absolute_config_path = ::File.expand_path(::File.join('config', 'action_subscriber.yml'))
          if ::File.exist?(absolute_config_path)
            erb_yaml = ::ERB.new(::File.read(absolute_config_path)).result
            # Defined in Psych 3.2+ and the new canonical way to load trusted documents:
            # https://github.com/ruby/psych/issues/533#issuecomment-1019363688
            yaml_config = ::YAML.respond_to?(:unsafe_load) ? ::YAML.unsafe_load(erb_yaml)[env] : ::YAML.load(erb_yaml)[env]
          end

          ::ActionSubscriber::Configuration::DEFAULTS.each_pair do |key, _value|
            exists, setting = fetch_config_value(key, cli_options, yaml_config)
            ::ActionSubscriber.config.__send__("#{key}=", setting) if exists
          end

          true
        end
      end
    end

    def self.fetch_config_value(key, cli_options, yaml_config)
      return [true, cli_options[key]] if cli_options.key?(key)
      return [true, cli_options[key.to_s]] if cli_options.key?(key.to_s)
      return [true, yaml_config[key]] if yaml_config.key?(key)
      return [true, yaml_config[key.to_s]] if yaml_config.key?(key.to_s)

      [false, nil]
    end
    private_class_method :fetch_config_value

    ##
    # Instance Methods
    #
    def initialize
      self.decoder = {
        'application/json' => ->(payload) { JSON.parse(payload) },
        'text/plain' => ->(payload) { payload.dup }
      }

      self.error_handler = lambda do |error, _env_hash|
        logger = ::ActionSubscriber::Logging.logger

        logger.error(error.message)
        logger.error(error.class.to_s)
        logger.error(error.backtrace.join("\n")) if error.try(:backtrace) && error.backtrace.is_a?(::Array)
      end

      DEFAULTS.each_pair do |key, value|
        __send__("#{key}=", value)
      end
    end

    ##
    # Instance Methods
    #
    def add_decoder(decoders)
      decoders.each_pair do |content_type, decoder|
        unless decoder.arity == 1
          raise "ActionSubscriber decoders must have an arity of 1. The #{content_type} decoder was given with arity of #{decoder.arity}."
        end
      end

      self.decoder.merge!(decoders)
    end

    def connection_string=(url)
      settings = ::ActionSubscriber::URI.parse_amqp_url(url)
      settings.each do |key, value|
        send("#{key}=", value)
      end
    end

    def hosts
      return @hosts if @hosts.size > 0

      [host]
    end

    def middleware
      @middleware ||= Middleware.initialize_stack
    end

    def inspect
      inspection_string = <<-INSPECT.strip_heredoc
        Rabbit Hosts: #{hosts}
        Rabbit Port: #{port}
        Threadpool Size: #{threadpool_size}
        Low Priority Subscriber: #{allow_low_priority_methods}
        Decoders:
      INSPECT
      decoder.each_key { |key| inspection_string << "  --#{key}\n" }
      inspection_string
    end
  end
end
