module V8
  # capture 99 stack frames on exception with normal details.
  # You can adjust these values for performance or turn of stack capture entirely
  V8::C::V8::SetCaptureStackTraceForUncaughtExceptions(true, 99, V8::C::StackTrace::kOverview)
  class Error < StandardError
    include Enumerable

    # @!attribute [r] value
    # @return [Object] the JavaScript value passed to the `throw` statement
    attr_reader :value

    # @!attribute [r] cause
    # @return [Exception] the underlying error (if any) that triggered this error to be raised
    attr_reader :cause

    # @!attribute [V8::StackTrace] javascript_backtrace
    # @return the complete JavaScript stack at the point this error was thrown
    attr_reader :javascript_backtrace

    alias_method :standard_error_backtrace, :backtrace

    def initialize(message, value, javascript_backtrace, cause = nil)
      super(message)
      @value = value
      @cause = cause
      @javascript_backtrace = javascript_backtrace
    end

    def causes
      [].tap do |causes|
        current = self
        until current.nil? do
          causes.push current
          current = current.respond_to?(:cause) ? current.cause : nil
        end
      end
    end

    def backtrace(*modifiers)
      return unless super()
      trace_framework = modifiers.include?(:framework)
      trace_ruby = modifiers.length == 0 || modifiers.include?(:ruby)
      trace_javascript = modifiers.length == 0 || modifiers.include?(:javascript)
      bilingual_backtrace(trace_ruby, trace_javascript).tap do |trace|
        trace.reject! {|frame| frame =~  %r{lib/v8/.*\.rb}} unless modifiers.include?(:framework)
      end
    end

    def root_cause
      causes.last
    end

    def in_javascript?
      causes.last.is_a? self.class
    end

    def in_ruby?
      !in_javascript?
    end

    def bilingual_backtrace(trace_ruby = true, trace_javascript = true)
      backtrace = causes.reduce(:backtrace => [], :ruby => -1, :javascript => -1) { |accumulator, cause|
        accumulator.tap do
          if trace_ruby
            backtrace_selector = cause.respond_to?(:standard_error_backtrace) ? :standard_error_backtrace : :backtrace
            ruby_frames = cause.send(backtrace_selector)[0..accumulator[:ruby]]
            accumulator[:backtrace].unshift *ruby_frames
            accumulator[:ruby] -= ruby_frames.length
          end
          if trace_javascript && cause.respond_to?(:javascript_backtrace)
            javascript_frames = cause.javascript_backtrace.to_a[0..accumulator[:javascript]].map(&:to_s)
            accumulator[:backtrace].unshift *javascript_frames
            accumulator[:javascript] -= javascript_frames.length
          end
        end
      }[:backtrace]
    end

    module Try
      def try
        V8::C::TryCatch() do |trycatch|
          result = yield
          if trycatch.HasCaught()
            raise V8::Error(trycatch)
          else
            result
          end
        end
      end
    end

    module Protect
      def protect
        yield
      rescue Exception => e
        error = V8::C::Exception::Error(e.message)
        error.SetHiddenValue("rr::Cause", V8::C::External::New(e))
        V8::C::ThrowException(error)
      end
    end

  end

  def self.Error(trycatch)
    exception = trycatch.Exception()
    value = exception.to_ruby
    cause = nil
    javascript_backtrace = V8::StackTrace.new(trycatch.Message().GetStackTrace())
    message = if !exception.kind_of?(V8::C::Value)
      exception.to_s
    elsif exception.IsNativeError()
      if cause = exception.GetHiddenValue("rr::Cause")
        cause = cause.Value()
      end
      # SyntaxErrors do not have a JavaScript stack (even if they occur during js execution).
      # To caputre where the error occured, we need to put it in the message
      if value['constructor'] == V8::Context.current['SyntaxError']
        info = trycatch.Message()
        resource_name = info.GetScriptResourceName().to_ruby
        "#{value['message']} at #{resource_name}:#{info.GetLineNumber()}:#{info.GetStartColumn() + 1}"
      else
        exception.Get("message").to_ruby
      end
    elsif exception.IsObject()
      value['message'] || value.to_s
    else
      value.to_s
    end
    V8::Error.new(message, value, javascript_backtrace, cause)
  end
  const_set :JSError, Error
end