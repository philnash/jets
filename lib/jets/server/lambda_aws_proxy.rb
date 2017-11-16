require 'cgi'
require 'stringio'

class Jets::Server
  # This doesnt really need to be middleware
  class LambdaAwsProxy
    def initialize(route, env)
      @route = route
      @env = env
      # @env.each do |k,v|
      #   puts "#{k}: #{v}"
      # end
      Jets.boot # need the project app code, call in here because it is close
        # to when API Gateway would load jets as part the main_processor
    end

    def response
      event = build_event
      context = {}

      controller_class = find_controller_class
      controller_action = find_controller_action
      # controller = PostsController.new(event, content)
      # resp = controller.edit
      resp = controller_class.process(event, context, find_controller_action)

      # Map lambda proxy response format to rack format
      puts "resp #{resp.inspect}".colorize(:cyan)
      status = resp["statusCode"]
      headers = resp["headers"] || {}
      headers = {'Content-Type' => 'text/html'}.merge(headers)
      body = resp["body"]

      [status, headers, [body]]
    end

    def build_event
      resource = @route.path(true) # posts/{id}/edit
      path = @env['PATH_INFO'].sub('/','') # remove beginning space
      {
        "resource" => "/#{resource}", # "/posts/{id}/edit"
        "path" => @env['PATH_INFO'],  # /posts/tung/edit
        "httpMethod" => @env['REQUEST_METHOD'], # GET
        "headers" => request_headers,
        "queryStringParameters" => query_string_parameters,
        "pathParameters" => @route.extract_parameters(path),
        "stageVariables" => nil,
        "requestContext" => {},
        "body" => get_body,
        "isBase64Encoded" => false,
      }
    end

    # Annoying. The headers part part of the AWS Lambda proxy structure
    # does not consisently use the same casing scheme for the header keys.
    # So sometimes it looks like this:
    #   Accept-Encoding
    # and sometimes it is looks like this:
    #   cache-control
    # Special cases when the casing doesn't match, we map it over.
    CASING_MAP = {
      "Cache-Control" => "cache-control",
      "Content-Type" => "content-type",
      "Origin" => "origin",
      "Upgrade-Insecure-Requests" => "upgrade-insecure-requests",
    }

    def request_headers
      headers = @env.select { |k,v| k =~ /^HTTP_/ }.inject({}) do |h,(k,v)|
          # map things like HTTP_USER_AGENT to "User-Agent"
          key = k.sub('HTTP_','').split('_').map(&:capitalize).join('-')
          h[key] = v
          h
        end
      # content type is not prepended with HTTP_ but is part of Lambda's event headers thankfully
      headers["Content-Type"] = @env["CONTENT_TYPE"] if @env["CONTENT_TYPE"]

      # adjust the casing so it matches the Lambda AWS Proxy's structure
      CASING_MAP.each do |nice_casing, bad_casing|
        if headers.has_key?(nice_casing)
          headers[bad_casing] = headers.delete(nice_casing)
        end
      end

      # There are also a couple of other headers that are specific to
      # AWS Lambda Proxy and API Gateway. Example:
      #
      # "X-Amz-Cf-Id": "W8DF6J-lx1bkV00eCiBwIq5dldTSGGiG4BinJlxvN_4o8fCZtbsVjw==",
      # "X-Amzn-Trace-Id": "Root=1-5a0dc1ac-58a7db712a57d6aa4186c2ac",
      # "X-Forwarded-For": "88.88.88.88, 54.239.203.117",
      # "X-Forwarded-Port": "443",
      # "X-Forwarded-Proto": "https",
      #
      # For sample dump of the event headers, check out:
      #    spec/fixtures/samples/event-headers-form-post.json

      headers
    end

    def query_string_parameters
      Rack::Utils.parse_nested_query(@env['QUERY_STRING'])
    end

    # To get the post body:
    #   rack.input: #<StringIO:0x007f8ccf8db9a0>
    def get_body
      # @env["rack.input"] should always in there and we should make the tests
      # always rack.input but handling it this way because it's simpler
      input = @env["rack.input"] || StringIO.new
      body = input.read
      # return nil for blank string, because thats what Lambda AWS_PROXY does
      body unless body.empty?
    end

    def find_controller_class
      # posts#edit => PostsController
      @route.controller_name.constantize
    end

    def find_controller_action
      @route.action_name
    end
  end
end
