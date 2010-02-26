require 'uri'
require 'cgi'

module Happening
  module S3
    class Item
    
      REQUIRED_FIELDS = [:server]
    
      attr_accessor :bucket, :aws_id, :options
    
      def initialize(bucket, aws_id, options = {})
        @options = {
          :timeout => 10,
          :on_error => nil,
          :on_success => nil,
          :server => 's3.amazonaws.com',
          :protocol => 'https',
          :aws_access_key_id => nil,
          :aws_secret_access_key => nil,
          :retry_count => 4,
          :permissions => 'private'
        }.update(options.symbolize_keys)
        options.assert_valid_keys(:timeout, :on_success, :on_error, :server, :protocol, :aws_access_key_id, :aws_secret_access_key, :retry_count, :permissions)
        @aws_id = aws_id.to_s
        @bucket = bucket.to_s
      
        validate
      end
    
      def get
        headers = needs_to_sign? ? aws.sign("GET", path) : {}
        Happening::Log.debug "GET #{url}"
        http = http_class.new(url).get(:timeout => options[:timeout], :head => headers)

        http.errback { error_callback(:get, http) }
        http.callback { success_callback(:get, http) }
        nil
      end
      
      def put(data)
        permissions = options[:permissions] != 'private' ? {'x-amz-acl' => options[:permissions] } : {}
        headers = needs_to_sign? ? aws.sign("PUT", path, permissions.update({'url' => path})) : {}
        Happening::Log.debug "PUT #{url}"
        http = http_class.new(url).put(:timeout => options[:timeout], :head => headers, :body => data)

        http.errback { error_callback(:put, http) }
        http.callback { success_callback(:put, http, data) }
        nil
      end
      
      def delete
        headers = needs_to_sign? ? aws.sign("DELETE", path, {'url' => path}) : {}
        Happening::Log.debug "DELETE #{url}"
        http = http_class.new(url).delete(:timeout => options[:timeout], :head => headers)

        http.errback { error_callback(:delete, http) }
        http.callback { success_callback(:delete, http) }
        nil
      end
    
      def url
        URI::Generic.new(options[:protocol], nil, server, port, nil, path(!dns_bucket?), nil, nil, nil).to_s
      end
    
      def http_class
        EventMachine::HttpRequest
      end
      
      def server
        dns_bucket? ? "#{bucket}.#{options[:server]}" : options[:server]
      end
      
      def path(with_bucket=true)
        with_bucket ? "/#{bucket}/#{CGI::escape(aws_id)}" : "/#{CGI::escape(aws_id)}"
      end
    
    protected
    
      def error_callback(http_method, http)
        call_user_error_handler(http)
      end
    
      def success_callback(http_method, http, data=nil)
        Happening::Log.debug "Response #{http.response_header.status}"
        case http.response_header.status
        when 0, 400, 401, 404, 403, 409, 411, 412, 416, 500, 503
          if should_retry?
            Happening::Log.debug "retrying after: status #{http.response_header.status rescue ''}"
            handle_retry(http_method, data)
          else
            call_user_error_handler(http)
          end
        when 300, 301, 303, 304, 307
          Happening::Log.info "being redirected_to: #{http.response_header['LOCATION'] rescue ''}"
          handle_redirect(http_method, http.response_header['LOCATION'], data)
        else
          call_user_success_handler(http)
        end
      end
      
      def call_user_error_handler(http)
        options[:on_error].call(http) if options[:on_error].respond_to?(:call)
      end
      
      def call_user_success_handler(http)
        options[:on_success].call(http) if options[:on_success].respond_to?(:call)
      end
      
      def should_retry?
        options[:retry_count] > 0
      end
      
      def handle_retry(http_method, data)
        if should_retry?
          new_request = self.class.new(bucket, aws_id, options.update(:retry_count => options[:retry_count] - 1 ))
          case http_method
          when :get
            new_request.get
          when :put
            new_request.put(data)
          when :delete
            new_request.delete
          else
            raise "unknown http method #{http_method}"
          end
        else
          Happening::Log.info "Re-tried too often - giving up" if Happening.debug?
        end
      end
    
      def handle_redirect(http_method, location, data)
        new_server, new_path = extract_location(location)

        new_request = self.class.new(bucket, aws_id, options.update(:server => new_server))
        case http_method
        when :get
          new_request.get
        when :put
          new_request.put(data)
        when :delete
          new_request.delete
        else
          raise "unknown http method #{http_method}"
        end
      end
    
      def extract_location(location)
        uri = URI.parse(location)
        if match = uri.host.match(/\A#{bucket}\.(.*)/)
          server = match[1]
          path = uri.path
        elsif match = uri.path.match(/\A\/#{bucket}\/(.*)/)
          server = uri.host
          path = match[1]
        else
          raise "being redirected to an not understood place: #{location}"
        end
        return server, path.sub(/^\//, '')
      end
    
      def needs_to_sign?
        options[:aws_access_key_id].present?
      end
    
      def dns_bucket?
        # http://docs.amazonwebservices.com/AmazonS3/2006-03-01/index.html?BucketRestrictions.html
        return false unless (3..63) === bucket.size
        bucket.split('.').each do |component|
          return false unless component[/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/]
        end
        true
      end
    
      def port
        (options[:protocol].to_s == 'https') ? 443 : 80
      end
    
      def validate
        raise ArgumentError, "need a bucket name" unless bucket.present?
        raise ArgumentError, "need a AWS Key" unless aws_id.present?
      
        REQUIRED_FIELDS.each do |field|
          raise ArgumentError, "need field #{field}" unless options[field].present?
        end
      
        raise ArgumentError, "unknown protocoll #{options[:protocol]}" unless ['http', 'https'].include?(options[:protocol])
      end
      
      def aws
        @aws ||= Happening::AWS.new(options[:aws_access_key_id], options[:aws_secret_access_key])
      end
    
    end
  end
end
