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

    Rails.logger.info "KrakenAccount::HoldingsProcessor - Processing #{holdings_data.size} raw holdings for account #{@kraken_account.id}"

    # Aggregate holdings by ticker (sum all types: spot + staked + bonds)
    aggregated = aggregate_holdings_by_ticker(holdings_data)
    Rails.logger.info "KrakenAccount::HoldingsProcessor - Aggregated to #{aggregated.size} unique tickers"

    # Get provider for price lookups
    provider = kraken_item&.kraken_provider

    aggregated.each do |ticker, data|
      begin
        process_aggregated_holding(ticker, data, provider)
      rescue => e
        Rails.logger.error "KrakenAccount::HoldingsProcessor - Failed to process #{ticker}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      end
    end
  end

  private

    # Aggregate holdings by ticker - sum quantities for spot + staked + bonds
    def aggregate_holdings_by_ticker(holdings_data)
      aggregated = {}

      holdings_data.each do |data|
        # Handle both string and symbol keys
        data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)

        ticker = data[:ticker]
        next if ticker.blank?

        # Skip fiat currencies
        next if %w[USD EUR GBP JPY CAD AUD].include?(ticker)

        # Convert to BigDecimal
        quantity = data[:quantity].to_s.to_d
        next if quantity.zero?

        aggregated[ticker] ||= { quantity: BigDecimal("0"), types: [] }
        aggregated[ticker][:quantity] += quantity
        aggregated[ticker][:types] << data[:type]
      end

      aggregated
    end

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

      # Skip fiat currencies - they're tracked as cash balance
      return if %w[USD EUR GBP JPY CAD AUD].include?(ticker)

      # Resolve or create the security using base ticker (without extension)
      # The holding_type is stored in the holding's extra metadata
      security = resolve_security(ticker, data, holding_type)
      return unless security

      # Get current price for valuation
      price = fetch_current_price(ticker, provider) || 0
      amount = price > 0 ? (quantity * price).round(2) : 0

      # Get account currency
      currency = account.currency || "USD"

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

    # Process an aggregated holding (sum of spot + staked + bonds)
    def process_aggregated_holding(ticker, data, provider)
      quantity = data[:quantity]
      return if quantity.zero?

      Rails.logger.info "KrakenAccount::HoldingsProcessor - Processing aggregated: #{ticker} qty=#{quantity}"

      # Resolve security
      security = resolve_security(ticker, {}, "Spot")
      return unless security

      # Get current price
      price = fetch_current_price(ticker, provider) || 0
      amount = price > 0 ? (quantity * price).round(2) : 0

      # Get account currency
      currency = account.currency || "USD"

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

      # Store metadata
      if holding.respond_to?(:extra) && holding.extra.is_a?(Hash)
        holding.extra["kraken"] = {
          "holding_types" => data[:types],
          "aggregated" => true
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
          # Build the correct Kraken pair
          # Kraken uses specific formats: XXBT (BTC), XETH (ETH), etc.
          kraken_base = case ticker
          when "BTC" then "XXBT"
          when "ETH" then "XETH"
          when "XRP" then "XXRP"
          when "LTC" then "XLTC"
          when "XLM" then "XXLM"
          when "DOT" then "XDOT"
          else "X#{ticker}"
          end

          # Try USD first, then USDT
          price = fetch_price_for_pair(provider, "#{kraken_base}ZUSD")
          return price if price

          price = fetch_price_for_pair(provider, "#{kraken_base}ZUSDT")
          return price if price

          price = fetch_price_for_pair(provider, "#{kraken_base}ZEUR")
          return price if price
        rescue => e
          Rails.logger.warn "KrakenAccount::HoldingsProcessor - Failed to fetch price from Kraken: #{e.message}"
        end
      end

      # Fall back to security's latest price if available
      security = Security.find_by(ticker: "CRYPTO:#{ticker}")
      if security
        latest_price = security.prices.order(date: :desc).first
        if latest_price.present? && latest_price.price > 0
          Rails.logger.info "KrakenAccount::HoldingsProcessor - Using stored price for #{ticker}: #{latest_price.price}"
          return latest_price.price
        end
      end

      # If no price available, return nil (matches Coinbase behavior)
      Rails.logger.warn "KrakenAccount::HoldingsProcessor - No price available for #{ticker}"
      nil
    end

    def fetch_price_for_pair(provider, pair)
      ticker_data = provider.get_ticker_information([ pair ])
      price = ticker_data.dig("result", pair, "c", 0)
      if price.present? && price.to_d > 0
        Rails.logger.info "KrakenAccount::HoldingsProcessor - Fetched price for #{pair}: #{price}"
        return price.to_d
      end
      nil
    rescue => e
      Rails.logger.debug "KrakenAccount::HoldingsProcessor - Pair #{pair} not available: #{e.message}"
      nil
    end
end
