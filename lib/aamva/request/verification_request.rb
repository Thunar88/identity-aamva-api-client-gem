require 'erb'
require 'faraday'
require 'rexml/document'
require 'rexml/xpath'
require 'securerandom'
require 'retries'

module Aamva
  module Request
    class VerificationRequest
      CONTENT_TYPE = 'application/soap+xml;charset=UTF-8'.freeze
      DEFAULT_VERIFICATION_URL =
        'https://verificationservices2-cert.aamva.org:18449/dldv/2.1/valuefree'.freeze
      SOAP_ACTION = '"http://aamva.org/dldv/wsdl/2.1/IDLDVService21/VerifyDriverLicenseData"'.freeze

      extend Forwardable

      attr_reader :config, :body, :headers, :url

      def initialize(config:, applicant:, session_id:, auth_token:)
        @config = config
        @applicant = applicant
        @transaction_id = session_id
        @auth_token = auth_token
        @url = verification_url
        @body = build_request_body
        @headers = build_request_headers
      end

      def send
        with_retries(max_tries: 2, rescue: [Faraday::TimeoutError, Faraday::ConnectionFailed]) do
          Response::VerificationResponse.new(
            http_client.post(url, body, headers)
          )
        end
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => err
        message = "AAMVA raised #{err.class} waiting for verification response: #{err.message}"
        raise ::Proofer::TimeoutError, message
      end

      def verification_url
        config.verification_url || DEFAULT_VERIFICATION_URL
      end

      private

      attr_reader :applicant, :transaction_id, :auth_token

      def http_client
        Faraday.new(request: { open_timeout: timeout, timeout: timeout }) do |faraday|
          faraday.adapter :net_http
        end
      end

      def add_user_provided_data_to_body
        document = REXML::Document.new(body)
        user_provided_data_map.each do |xpath, data|
          REXML::XPath.first(document, xpath).add_text(data)
        end
        @body = document.to_s
      end

      def build_request_body
        renderer = ERB.new(request_body_template)
        @body = renderer.result(binding)
        add_user_provided_data_to_body
      end

      def build_request_headers
        {
          'SOAPAction' => SOAP_ACTION,
          'Content-Type' => CONTENT_TYPE,
          'Content-Length' => body.length.to_s,
        }
      end

      def document_category_code
        case applicant.state_id_data.state_id_type
        when 'drivers_license'
          '1'
        when 'drivers_permit'
          '2'
        when 'state_id_card'
          '3'
        end
      end

      def message_destination_id
        return 'P6' if config.cert_enabled.to_s == 'true'
        applicant.state_id_data.state_id_jurisdiction
      end

      def request_body_template
        template_file_path = File.join(
          File.dirname(__FILE__),
          'templates/verify.xml.erb'
        )
        File.read(template_file_path)
      end

      def transaction_locator_id
        applicant.uuid
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def user_provided_data_map
        applicant_address = applicant.address
        {
          '//ns2:IdentificationID' => applicant.state_id_data.state_id_number,
          '//ns1:DocumentCategoryCode' => document_category_code,
          '//ns1:MessageOriginatorId' => applicant.message_originator_id,
          '//ns1:MessageDestinationId' => message_destination_id,
          '//ns2:PersonGivenName' => applicant.first_name,
          '//ns2:PersonSurName' => applicant.last_name,
          '//ns2:PersonMiddleName' => applicant.middle_name,
          '//ns2:PersonNameSuffixText' => applicant.suffix,
          '//ns1:DriverLicenseIssueDate' => applicant.issue_date,
          '//ns1:DriverLicenseExpirationDate' => applicant.expiration_date,
          '//ns1:PersonBirthDate' => applicant.dob,
          '//ns2:LocationCityName' => applicant.city,
          '//ns2:LocationStateUsPostalServiceCode' => applicant.state,
          '//ns2:LocationPostalCode' => applicant.zip_code
        }
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def uuid
        SecureRandom.uuid
      end

      def timeout
        (config.verification_request_timeout || 5).to_i
      end
    end
  end
end
