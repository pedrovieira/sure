# frozen_string_literal: true

class Provider::Kraken
  include HTTParty

  # Kraken API base URL
  API_BASE_URL = "https://api.kraken.com".freeze
  ASSET_INFO_CACHE_TTL = 1.day

  headers "User-Agent" => "Sure Finance Kraken Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end
  class InvalidNonceError < Error; end

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
    validate_configuration!
  end

  # Get account balance (spot balances)
  # Returns hash like { "XXBT" => "0.5", "XETH" => "2.0" }
  def get_account_balance
    post_private("/0/private/Balance")
  end

  # Get extended balance (includes staking/earn positions)
  # Returns hash with asset codes including .S, .F, .M extensions
  def get_extended_balance
    post_private("/0/private/BalanceEx")
  end

  # Get ledger entries (transaction history)
  # @param start_time [Integer] Unix timestamp (optional)
  # @param end_time [Integer] Unix timestamp (optional)
  # @param offset [Integer] Pagination offset
  # @return [Hash] Ledger entries
  def get_ledgers(start_time: nil, end_time: nil, offset: 0)
    params = {}
    params[:start] = start_time if start_time
    params[:end] = end_time if end_time
    params[:ofs] = offset if offset > 0

    post_private("/0/private/Ledgers", params)
  end

  # Get asset info for normalizing asset codes
  # Cached for 24 hours to reduce API calls
  # @return [Hash] Asset info mapping
  def get_asset_info
    post_public("/0/public/Assets")
  end

  # Get trade balance (portfolio valuation)
  # @param asset [String] Optional base asset for valuation
  # @return [Hash] Trade balance info
  def get_trade_balance(asset: nil)
    params = {}
    params[:asset] = asset if asset.present?
    post_private("/0/private/TradeBalance", params)
  end

  # Get ticker information for multiple pairs
  # @param pairs [Array<String>] Asset pairs (e.g., ["XXBTZUSD", "XETHZUSD"])
  # @return [Hash] Ticker data
  def get_ticker_information(pairs)
    pair_string = pairs.join(",")
    post_public("/0/public/Ticker", { pair: pair_string })
  end

  # Asset info mapping with caching
  # Maps Kraken asset codes to standard tickers
  # @return [Hash] { "XXBT" => "BTC", "ZUSD" => "USD", ... }
  def asset_info_map
    Rails.cache.fetch("kraken_asset_info", expires_in: ASSET_INFO_CACHE_TTL) do
      response = get_asset_info
      build_asset_mapping(response)
    end
  end

  # Normalize a Kraken asset code to standard ticker
  # Separates base code from extension (staking/earn types)
  # @param kraken_code [String] Kraken asset code (e.g., "XXBT.S", "XETH.F")
  # @return [Array<String, String>] [normalized_ticker, extension]
  #   e.g., normalize_asset_code("XXBT.S") => ["BTC", "S"]
  def normalize_asset_code(kraken_code)
    # Separate base code from extension (.S, .F, .M, .B)
    base_code = kraken_code.to_s.gsub(/\.[SMFBT]$/, "")
    extension = kraken_code.to_s.match(/\.([SMFBT])$/)&.[](1)

    # Map to standard ticker using cached asset info
    mapping = asset_info_map
    normalized = mapping[base_code]

    # Fallback: strip X/Z prefix if no mapping found
    if normalized.nil?
      normalized = base_code.gsub(/^[XZ]/, "")
    end

    [ normalized, extension ]
  end

  # Determine holding type from extension
  # @param extension [String] Asset extension (.S, .F, .M, etc.)
  # @return [String] Holding type label
  def holding_type_from_extension(extension)
    case extension
    when "S"
      "Staked"
    when "F"
      "Earn"
    when "M"
      "Margin"
    when "B"
      "Bonds"
    when "T"
      "Terms"
    else
      "Spot"
    end
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "API key is required" if @api_key.blank?
      raise ConfigurationError, "API secret is required" if @api_secret.blank?
    end

    # Build asset mapping from Kraken API response
    # @param response [Hash] API response from get_asset_info
    # @return [Hash] Mapping of Kraken codes to standard tickers
    def build_asset_mapping(response)
      return {} unless response.is_a?(Hash) && response["result"].is_a?(Hash)

      result = response["result"]
      mapping = {}

      result.each do |kraken_code, info|
        # Use altname if available, otherwise strip X/Z prefix
        altname = info["altname"]
        if altname.present?
          mapping[kraken_code] = altname
        else
          # Fallback: strip X/Z prefix
          mapping[kraken_code] = kraken_code.gsub(/^[XZ]/, "")
        end
      end

      mapping
    end

    # Make a public API request (no authentication required)
    def post_public(path, params = {})
      url = "#{API_BASE_URL}#{path}"

      with_retries("post_public") do
        response = self.class.post(
          url,
          body: params.to_query,
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        )

        handle_response(response)
      end
    end

    # Make a private API request (requires authentication)
    def post_private(path, params = {})
      url = "#{API_BASE_URL}#{path}"
      nonce = generate_nonce
      params_with_nonce = params.merge(nonce: nonce)
      post_data = params_with_nonce.to_query

      with_retries("post_private") do
        response = self.class.post(
          url,
          body: post_data,
          headers: auth_headers(path, nonce, post_data)
        )

        handle_response(response)
      end
    end

    # Generate authentication headers for Kraken API
    # Uses HMAC-SHA512 signature
    def auth_headers(path, nonce, post_data)
      # Create the message: nonce + POST data
      # POST data must be URL-encoded
      message = nonce.to_s + post_data
      sha256_hash = Digest::SHA256.digest(message)

      # HMAC data: path (as bytes) + SHA256 hash (as bytes)
      hmac_data = path.dup.force_encoding("ASCII-8BIT") + sha256_hash

      # Decode base64 secret and create HMAC
      decoded_secret = Base64.decode64(@api_secret)
      hmac = OpenSSL::HMAC.digest("SHA512", decoded_secret, hmac_data)
      signature = Base64.strict_encode64(hmac)

      {
        "API-Key" => @api_key,
        "API-Sign" => signature,
        "Content-Type" => "application/x-www-form-urlencoded"
      }
    end

    # Generate a unique nonce (microsecond timestamp)
    def generate_nonce
      (Time.now.to_f * 1_000_000).to_i
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Kraken API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Kraken API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def handle_response(response)
      parsed = JSON.parse(response.body)

      # Check for Kraken API errors
      if parsed["error"]&.any?
        error_msg = parsed["error"].join(", ")
        Rails.logger.error "Kraken API Error: #{error_msg}"
        handle_kraken_error(error_msg, parsed)
      end

      case response.code
      when 200, 201
        parsed
      when 400
        Rails.logger.error "Kraken API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{error_msg}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid API credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check API permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise RateLimitError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise ApiError.new("Kraken server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Kraken API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{error_msg}", :unknown)
      end
    end

    def handle_kraken_error(error_msg, parsed)
      # Handle specific Kraken error codes
      case error_msg
      when /EAPI:Invalid key/
        raise AuthenticationError.new("Invalid API key", :invalid_key)
      when /EAPI:Invalid signature/
        raise AuthenticationError.new("Invalid API signature - check your secret", :invalid_signature)
      when /EAPI:Invalid nonce/
        raise InvalidNonceError.new("Invalid nonce - check your system clock", :invalid_nonce)
      when /EService:Unavailable/
        raise ApiError.new("Kraken service temporarily unavailable", :service_unavailable)
      when /EService:Busy/
        raise RateLimitError.new("Kraken is busy - please retry", :busy)
      when /EGeneral:Permission denied/
        raise AuthenticationError.new("Permission denied - check API key permissions", :permission_denied)
      when /EGeneral:Invalid arguments/
        raise Error.new("Invalid arguments provided", :invalid_arguments)
      when /EOrder:Rate limit exceeded/
        raise RateLimitError.new("Rate limit exceeded", :rate_limited)
      else
        # Unknown Kraken API error - raise generic error
        raise ApiError.new("Kraken API error: #{error_msg}", :api_error)
      end
    end
end
