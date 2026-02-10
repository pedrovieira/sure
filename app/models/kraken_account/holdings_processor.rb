# frozen_string_literal: true

# Processes Kraken account holdings to create/update Holding records.
# Handles spot, staked, and earn positions as separate holdings.
class KrakenAccount::HoldingsProcessor
  include KrakenAccount::DataHelpers

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless account.present?

    holdings_data = @kraken_account.raw_holdings_payload
    return if holdings_data.blank?

    Rails.logger.info "KrakenAccount::HoldingsProcessor - Processing #{holdings_data.size} holdings for account #{@kraken_account.id}"

    # Get provider for price lookups
    provider = kraken_item&.kraken_provider

    holdings_data.each_with_index do |holding_data, idx|
      begin
        process_holding(holding_data.with_indifferent_access, provider)
      rescue => e
        Rails.logger.error "KrakenAccount::HoldingsProcessor - Failed to process holding #{idx + 1}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      end
    end
  end

  private

    def kraken_item
      @kraken_account.kraken_item
    end

    def account
      @kraken_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_holding(data, provider)
      ticker = data[:ticker]
      return if ticker.blank?

      holding_type = data[:type] || "Spot"
      quantity = data[:quantity].to_d
      return if quantity.zero?

      # Create unique ticker based on holding type
      # e.g., BTC for spot, BTC.S for staked
      ticker_with_type = holding_type == "Spot" ? ticker : "#{ticker}.#{holding_type.first}"

      Rails.logger.info "KrakenAccount::HoldingsProcessor - Processing #{holding_type} holding: #{ticker_with_type} qty=#{quantity}"

      # Resolve or create the security
      security = resolve_security(ticker_with_type, data, holding_type)
      return unless security

      # Get current price for valuation
      price = fetch_current_price(ticker, provider)
      amount = price > 0 ? (quantity * price).round(2) : 0

      # Get account currency
      currency = account.currency || "USD"

      Rails.logger.info "KrakenAccount::HoldingsProcessor - Importing holding: #{ticker_with_type} qty=#{quantity} price=#{price} amount=#{amount}"

      # Import the holding
      holding = import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: Date.current,
        price: price,
        account_provider_id: @kraken_account.account_provider&.id,
        source: "kraken",
        delete_future_holdings: false
      )

      # Store Kraken-specific metadata in the holding's extra field
      if holding.respond_to?(:extra) && holding.extra.is_a?(Hash)
        holding.extra["kraken"] = {
          "asset_code" => data[:kraken_asset_code],
          "holding_type" => holding_type,
          "raw_balance" => data[:raw_data]
        }
        holding.save!
      end
    end

    # Resolve security for this holding
    # Uses CRYPTO: prefix to distinguish from stock tickers
    def resolve_security(ticker, data, holding_type)
      # Create ticker with CRYPTO: prefix
      crypto_ticker = ticker.include?(":") ? ticker : "CRYPTO:#{ticker}"

      begin
        Security::Resolver.new(crypto_ticker).resolve
      rescue => e
        Rails.logger.debug(
          "KrakenAccount::HoldingsProcessor - Resolver failed for #{crypto_ticker}: #{e.message}; creating offline security"
        )

        # Fall back to creating an offline security
        Security.find_or_create_by(ticker: crypto_ticker) do |security|
          security.name = build_security_name(data, holding_type)
          security.exchange_operating_mic = "XKRK" # Kraken exchange MIC
          security.offline = true if security.respond_to?(:offline=)
        end
      end
    end

    def build_security_name(data, holding_type)
      base_name = data[:ticker]
      case holding_type
      when "Staked"
        "#{base_name} (Staked)"
      when "Earn"
        "#{base_name} (Earn)"
      when "Margin"
        "#{base_name} (Margin)"
      when "Bonds"
        "#{base_name} (Bonds)"
      else
        base_name
      end
    end

    # Fetch current price for valuation
    def fetch_current_price(ticker, provider)
      # Try to get price from Kraken's ticker API
      if provider
        begin
          pair = "X#{ticker}ZUSD"
          ticker_data = provider.get_ticker_information([ pair ])

          if ticker_data.dig("result", pair, "c").present?
            # Last trade price is in 'c' array, first element
            price = ticker_data.dig("result", pair, "c", 0)
            return price.to_d if price.present?
          end
        rescue => e
          Rails.logger.warn "KrakenAccount::HoldingsProcessor - Failed to fetch price from Kraken: #{e.message}"
        end
      end

      # Fall back to security's latest price if available
      security = Security.find_by(ticker: "CRYPTO:#{ticker}")
      if security
        latest_price = security.prices.order(date: :desc).first
        return latest_price.price if latest_price.present?
      end

      # If no price available, return 0
      Rails.logger.warn "KrakenAccount::HoldingsProcessor - No price available for #{ticker}"
      0
    end
end
