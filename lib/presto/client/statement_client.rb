#
# Presto client for Ruby
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Presto::Client

  require 'multi_json'
  require 'presto/client/models'
  require 'presto/client/errors'

  module PrestoHeaders
    PRESTO_USER = "X-Presto-User"
    PRESTO_SOURCE = "X-Presto-Source"
    PRESTO_CATALOG = "X-Presto-Catalog"
    PRESTO_SCHEMA = "X-Presto-Schema"

    PRESTO_CURRENT_STATE = "X-Presto-Current-State"
    PRESTO_MAX_WAIT = "X-Presto-Max-Wait"
    PRESTO_MAX_SIZE = "X-Presto-Max-Size"
    PRESTO_PAGE_SEQUENCE_ID = "X-Presto-Page-Sequence-Id"
  end

  class StatementClient
    HEADERS = {
      "User-Agent" => "presto-ruby/#{VERSION}"
    }

    def initialize(faraday, query, options)
      @faraday = faraday
      @faraday.headers.merge!(HEADERS)

      @options = options
      @query = query
      @closed = false
      @exception = nil
      post_query_request!
    end

    def init_request(req)
      req.options.timeout = @options[:http_timeout] || 300
      req.options.open_timeout = @options[:http_open_timeout] || 60
    end

    private :init_request

    def post_query_request!
      response = @faraday.post do |req|
        req.url "/v1/statement"

        if v = @options[:user]
          req.headers[PrestoHeaders::PRESTO_USER] = v
        end
        if v = @options[:source]
          req.headers[PrestoHeaders::PRESTO_SOURCE] = v
        end
        if v = @options[:catalog]
          req.headers[PrestoHeaders::PRESTO_CATALOG] = v
        end
        if v = @options[:schema]
          req.headers[PrestoHeaders::PRESTO_SCHEMA] = v
        end

        req.body = @query
      end

      # TODO error handling
      if response.status != 200
        raise PrestoHttpError.new(response.status, "Failed to start query: #{response.body}")
      end

      body = response.body
      hash = MultiJson.load(body)
      @results = QueryResults.decode_hash(hash)
    end

    private :post_query_request!

    attr_reader :query

    def debug?
      !!@options[:debug]
    end

    def closed?
      @closed
    end

    attr_reader :exception

    def exception?
      @exception
    end

    def query_failed?
      @results.error != nil
    end

    def query_succeeded?
      @results.error == nil && !@exception && !@closed
    end

    def current_results
      @results
    end

    def has_next?
      !!@results.next_uri
    end

    def advance
      if closed? || !has_next?
        return false
      end
      uri = @results.next_uri

      start = Time.now
      attempts = 0

      begin
        begin
          response = @faraday.get do |req|
            req.url uri
          end
        rescue => e
          @exception = e
          raise @exception
        end

        if response.status == 200 && !response.body.to_s.empty?
          @results = QueryResults.decode_hash(MultiJson.load(response.body))
          return true
        end

        if response.status != 503  # retry on 503 Service Unavailable
          # deterministic error
          @exception = PrestoHttpError.new(response.status, "Error fetching next at #{uri} returned #{response.status}: #{response.body}")
          raise @exception
        end

        attempts += 1
        sleep attempts * 0.1
      end while (Time.now - start) < 2*60*60 && !@closed

      @exception = PrestoHttpError.new(408, "Error fetching next due to timeout")
      raise @exception
    end

    def cancel_leaf_stage
      if uri = @results.next_uri
        response = @faraday.delete do |req|
          req.url uri
        end
        return response.status / 100 == 2
      end
      return false
    end

    def close
      return if @closed

      # cancel running statement
      # TODO make async reqeust and ignore response?
      cancel_leaf_stage

      @closed = true
      nil
    end
  end

end
