# frozen_string_literal: true

module KrakenItem::Provided
  extend ActiveSupport::Concern

  def kraken_provider
    return nil unless credentials_configured?

    Provider::Kraken.new(
      api_key: api_key,
      api_secret: api_secret
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def kraken_credentials
    return nil unless credentials_configured?

    {
      api_key: api_key,
      api_secret: api_secret
    }
  end
end
