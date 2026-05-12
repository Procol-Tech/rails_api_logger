require "spec_helper"
require "action_dispatch"
require "rack"

RSpec.describe RequestLog do
  describe ".from_request" do
    before { allow(InboundRequestLog).to receive(:switch_tenant).and_return(nil) }

    def build_request(body:, query_string: "", content_type: "application/json")
      path = "/api/v1/things" + (query_string.empty? ? "" : "?#{query_string}")
      env = Rack::MockRequest.env_for(
        path,
        method: "PATCH",
        input: body,
        "CONTENT_TYPE" => content_type
      )
      ActionDispatch::Request.new(env)
    end

    context "when JSON body is a Hash and query parameters are present" do
      it "merges query parameters into the body Hash" do
        request = build_request(body: '{"a":1,"b":2}', query_string: "rfx_number=RFX-8899")
        log = InboundRequestLog.from_request(request)
        expect(log.request_body).to eq("a" => 1, "b" => 2, "rfx_number" => "RFX-8899")
      end
    end

    context "when JSON body is an Array and query parameters are present" do
      it "preserves the Array under _json and includes query parameters" do
        request = build_request(body: '[{"prNo":"0200715434"}]', query_string: "rfx_number=RFX-8899")
        log = InboundRequestLog.from_request(request)
        expect(log.request_body).to eq(
          "_json" => [{ "prNo" => "0200715434" }],
          "rfx_number" => "RFX-8899"
        )
      end
    end

    context "when body is empty and query parameters are present" do
      it "stores query parameters as the body" do
        request = build_request(body: "", query_string: "rfx_number=RFX-8899")
        log = InboundRequestLog.from_request(request)
        expect(log.request_body).to eq("rfx_number" => "RFX-8899")
      end
    end

    context "when JSON body is an Array and no query parameters" do
      it "stores the Array as-is" do
        request = build_request(body: '[{"prNo":"0200715434"}]')
        log = InboundRequestLog.from_request(request)
        expect(log.request_body).to eq([{ "prNo" => "0200715434" }])
      end
    end
  end

  describe ".failed" do
    [OutboundRequestLog, InboundRequestLog].each do |klass|
      it "returns only failed requests for #{klass}" do
        klass.create!(path: "/ok", method: "GET", response_code: 200)
        klass.create!(path: "/redirecting", method: "GET", response_code: 308)
        klass.create!(path: "/bad_request", method: "GET", response_code: 400)
        klass.create!(path: "/server_error", method: "GET", response_code: 500)
        klass.create!(path: "/long_and_still_running", method: "GET", response_code: nil, ended_at: nil)
        klass.create!(path: "/timeout", method: "GET", response_code: nil, ended_at: 1.hour.ago)

        expect(klass.failed).to contain_exactly(
          having_attributes(path: "/bad_request"),
          having_attributes(path: "/server_error"),
          having_attributes(path: "/timeout")
        )
      end
    end
  end

  describe "#from_response" do
    let(:uri) { URI("http://example.com/some_path?query=string") }
    let(:http) { Net::HTTP.new(uri.host, uri.port) }
    let(:request) { Net::HTTP::Get.new(uri) }
    let(:response) { http.start { |http| http.request(request) } }

    before { RailsApiLogger.new(skip_body: skip_body).call(uri, request) { response } }

    context "when skip_body is set to false" do
      let(:skip_body) { false }

      it "sets the response_body to the original request's response body" do
        log = OutboundRequestLog.last
        expect(log.response_body).to eq(response.body)
      end
    end

    context "when skip_body is set to true" do
      let(:skip_body) { true }

      it "sets the response_body to [Skipped]" do
        log = OutboundRequestLog.last
        expect(log.response_body).to eq("[Skipped]")
      end
    end
  end
end
