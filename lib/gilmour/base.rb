# encoding: utf-8
# This is required to check whether Mash class already exists
require 'logger'
require 'securerandom'
require 'json'
require 'mash' unless class_exists? 'Mash'
require 'eventmachine'

require_relative 'protocol'
require_relative 'responder'
require_relative 'backends/backend'

# The Gilmour module
module Gilmour
  LoggerLevels = {
    unknown: Logger::UNKNOWN,
    fatal: Logger::FATAL,
    error: Logger::ERROR,
    warn: Logger::WARN,
    info: Logger::INFO,
    debug: Logger::DEBUG
  }


  GLogger = Logger.new(STDERR)
  EnvLoglevel =  ENV["LOG_LEVEL"] ? ENV["LOG_LEVEL"].to_sym : :warn
  GLogger.level = LoggerLevels[EnvLoglevel] || Logger::DEBUG

  RUNNING = false
  # This is the base module that should be included into the
  # container class
  module Base
    def self.included(base)
      base.extend(Registrar)
    end

    ######### Registration module ###########
    # This module helps act as a Resistrar for subclasses
    module Registrar
      attr_accessor :subscribers_path
      attr_accessor :backend
      DEFAULT_SUBSCRIBER_PATH = 'subscribers'
      @@subscribers = {} # rubocop:disable all
      @@registered_services = []

      def inherited(child) #:nodoc:
        @@registered_services << child
      end


      # Returns the subscriber classes registered
      def registered_subscribers
        @@registered_services
      end

      # This is the underlying layer of communication. Use if you
      # know what you are doing. Use "reply_to" and "slot" instead.
      #
      # Adds a listener for the given topic
      # +topic+:: The topic to listen to
      # +opts+:: Hash of optional arguments. Supported options are:
      #          exclusive:: If true, this listener is added to a group of listeners
      #          with the same name as the name of the class in which this
      #          method is called. A message sent to the _topic_ will be
      #          processed by at most one listener from a group 
      #          timeout:: Maximum duration (seconds) that a subscriber has to
      #          finish the task. If the execution exceeds the timeout, gilmour
      #          responds with status {code:409, data: nil}
      #
      def listen_to(topic, opts={}, &handler)
        opt_defaults = {
          exclusive: false,
          timeout: 600,
          fork: false
        }.merge(opts)

        #Make sure these are not overriden by opts.
        opt_defaults[:handler] = handler
        opt_defaults[:subscriber] = self

        @@subscribers[topic] ||= []
        @@subscribers[topic] << opt_defaults
      end
      alias_method :add_listener, :listen_to

      # Add a reply listener
      def reply_to(topic, opts={}, &handler)
        defopts = opts.merge({
          type: :reply
        })
        listen_to(topic, defopts, &handler)
      end

      # Add a slot listener
      def slot(topic, opts={}, &handler)
        defopts = opts.merge({
          type: :slot
        })
        listen_to(topic, defopts, &handler)
      end

      # Returns the list of subscribers for _topic_ or all subscribers if it is nil
      # Params:
      # +topic+:: The topic for which to return the subscribers. All subscribers are
      # returned if this is not provided
      def subscribers(topic = nil)
        if topic
          @@subscribers[topic]
        else
          @@subscribers
        end
      end

      # Loads all ruby source files inside _dir_ as subscribers
      # Should only be used inside the parent container class
      # Params:
      # +dir+:: relative path of directory to load subscribers from
      def load_all(dir = nil)
        dir ||= (subscribers_path || DEFAULT_SUBSCRIBER_PATH)
        Dir["#{dir}/*.rb"].each { |f| require f }
      end

      def load_subscriber(path) #:nodoc:
        require path
      end
    end

    def registered_subscribers #:nodoc:
      self.class.registered_subscribers
    end
    ############ End Register ###############

    class << self
      attr_accessor :backend
    end
    attr_reader :backends

    # Enable and return the given backend
    # Params
    # +name+:: the backend name (currently only 'redis' is supported)
    # +opts+:: backend specific options. Options for redis are
    #          host:: the redis server hostname
    #          port:: the redis server port
    #          braodcast_errors:: whether error reorting should be turned on
    #          health_check:: whether health_check hartbeats should be enabled
    def enable_backend(name, opts = {})
      Gilmour::Backend.load_backend(name)
      @backends ||= {}
      @backends[name] ||= Gilmour::Backend.get(name).new(opts)
    end
    alias_method :get_backend, :enable_backend

    # Cleanup the susbcribers and health checks
    def tear_down!
      subs_by_backend = subs_grouped_by_backend
      subs_by_backend.each do |b, subs|
        backend = get_backend(b)
        if backend.report_health?
          backend.unregister_health_check
        end
      end
    end

    # Starts all the listeners
    # If _startloop_ is true, this method will start it's own
    # event loop and not return till Eventmachine reactor is stopped
    # Params:
    # +startloop+:: If true this call with join the eventmachine thred and
    # block till it is done.
    def start(startloop = false)
      subs_by_backend = subs_grouped_by_backend
      subs_by_backend.each do |b, subs|
        backend = get_backend(b)
        subs.each do |topic, handlers|
          handlers.each do |handler|
            if handler[:type] == :slot
              backend.slot(topic, handler)
            elsif handler[:type] == :reply
              backend.reply_to(topic, handler)
            else
              backend.add_listener(topic, handler)
            end
          end
        end
        if backend.report_health?
          backend.register_health_check
        end
      end
      if startloop #Move into redis backend
        GLogger.debug 'Joining EM event loop'
        EM.reactor_thread.join
      end
    end

    private

    def subs_grouped_by_backend
      subs_by_backend = {}
      self.class.subscribers.each do |topic, subs|
        subs.each do |sub|
          subs_by_backend[sub[:subscriber].backend] ||= {}
          subs_by_backend[sub[:subscriber].backend][topic] ||= []
          subs_by_backend[sub[:subscriber].backend][topic] << sub
        end
      end
      subs_by_backend
    end
  end
end
