# frozen_string_literal: true

# Imports data from Kraken API for a single portfolio-style account.
# Unlike Coinbase which has multiple wallets, Kraken returns one balance object
# containing all assets (spot + staking + earn).
class KrakenItem::Importer
  include SyncStats::Collector

  # Maximum ledger entries to fetch per request
  LEDGER_CHUNK_SIZE = 50
  MAX_LEDGER_CHUNKS = 100 # Safety limit

  # Known fiat currencies for cash calculation
  FIAT_CURRENCIES = %w[USD EUR GBP JPY CAD AUD CHF].freeze

  attr_reader :kraken_item, :kraken_provider, :sync

  def initialize(kraken_item, kraken_provider:, sync: nil)
    @kraken_item = kraken_item
    @kraken_provider = kraken_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "KrakenItem::Importer - Starting import for item #{kraken_item.id}"

    unless kraken_item.credentials_configured?
      raise CredentialsError, "Kraken credentials not configured for item #{kraken_item.id}"
    end

    # Step 1: Create/update the single portfolio account
    import_portfolio_account

    # Step 2: Import holdings data (balances)
    import_holdings

    # Step 3: Import ledger entries (transactions)
    import_ledger

    # Update raw payload on the item
    kraken_item.upsert_kraken_snapshot!(stats)
  rescue Provider::Kraken::AuthenticationError => e
    kraken_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    # Kraken has a single portfolio account per item
    def import_portfolio_account
      Rails.logger.info "KrakenItem::Importer - Importing portfolio account"

      # Fetch trade balance for portfolio valuation
      trade_balance = kraken_provider.get_trade_balance
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      # Create or update the single portfolio account
      kraken_account = kraken_item.kraken_accounts.find_or_initialize_by(
        kraken_account_id: "kraken-portfolio"
      )

      # Get the equity balance (total value including P&L)
      total_value = trade_balance.dig("result", "eb") || trade_balance.dig("result", "tb") || 0

      # Calculate cash balance from fiat holdings only
      # For crypto-only accounts, cash is essentially 0
      extended_balance = kraken_provider.get_extended_balance
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      fiat_cash = calculate_fiat_cash_from_balance(extended_balance)

      kraken_account.upsert_from_kraken!({
        account_id: "kraken-portfolio",
        name: "Kraken Portfolio",
        current_balance: total_value.to_d,
        currency: "USD",
        cash_balance: fiat_cash,
        account_status: "active",
        account_type: "crypto",
        institution_metadata: {
          name: "Kraken",
          domain: "kraken.com",
          url: "https://www.kraken.com"
        },
        raw_payload: trade_balance
      })

      stats["accounts_imported"] = 1
      stats["total_accounts"] = 1

      persist_stats!

      kraken_account
    rescue => e
      Rails.logger.error "KrakenItem::Importer - Failed to import portfolio: #{e.message}"
      register_error(e, context: "portfolio_import")
      raise
    end

    # Import holdings from both spot and extended balances
    def import_holdings
      Rails.logger.info "KrakenItem::Importer - Importing holdings"

      kraken_account = kraken_item.kraken_accounts.find_by(kraken_account_id: "kraken-portfolio")
      return unless kraken_account

      # Fetch extended balance (includes spot + staking + earn)
      extended_balance = kraken_provider.get_extended_balance
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      # Build holdings list from balances
      holdings = build_holdings_from_balances(extended_balance)

      # Store holdings snapshot
      kraken_account.upsert_holdings_snapshot!(holdings)

      stats["holdings_found"] = holdings.size
      stats["spot_holdings"] = holdings.count { |h| h[:type] == "Spot" }
      stats["staked_holdings"] = holdings.count { |h| h[:type] == "Staked" }
      stats["earn_holdings"] = holdings.count { |h| h[:type] == "Earn" }

      persist_stats!

      Rails.logger.info "KrakenItem::Importer - Imported #{holdings.size} holdings"
    rescue => e
      Rails.logger.error "KrakenItem::Importer - Failed to import holdings: #{e.message}"
      register_error(e, context: "holdings_import")
    end

    # Build holdings array from Kraken balance response
    def build_holdings_from_balances(balance_response)
      return [] unless balance_response.is_a?(Hash) && balance_response["result"].is_a?(Hash)

      result = balance_response["result"]
      holdings = []

      result.each do |asset_code, balance_data|
        # Skip zero balances
        balance = balance_data.is_a?(Hash) ? balance_data["balance"] : balance_data
        next if balance.to_d.zero?

        # Normalize asset code
        normalized_ticker, extension = kraken_provider.normalize_asset_code(asset_code)
        holding_type = kraken_provider.holding_type_from_extension(extension)

        holdings << {
          kraken_asset_code: asset_code,
          ticker: normalized_ticker,
          type: holding_type,
          quantity: balance.to_d,
          raw_data: balance_data.is_a?(Hash) ? balance_data : { balance: balance }
        }
      end

      holdings
    end

    # Import ledger entries (transactions)
    def import_ledger
      Rails.logger.info "KrakenItem::Importer - Importing ledger entries"

      kraken_account = kraken_item.kraken_accounts.find_by(kraken_account_id: "kraken-portfolio")
      return unless kraken_account

      # Determine start date for ledger fetch
      start_time = calculate_ledger_start_time(kraken_account)

      # Fetch ledger entries with pagination
      all_ledgers = []
      offset = 0
      chunks_fetched = 0

      loop do
        response = kraken_provider.get_ledgers(
          start_time: start_time,
          offset: offset
        )
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        chunks_fetched += 1

        ledgers = response.dig("result", "ledger") || {}
        break if ledgers.empty?

        # Convert to array preserving internal refid (trade reference)
        # The hash key is the ledger entry ID, but the internal refid field
        # is what groups related entries (e.g., both sides of a trade)
        ledgers.each do |ledger_id, ledger_data|
          all_ledgers << ledger_data.merge("ledger_id" => ledger_id)
        end

        # Check if we've reached the end
        count = response.dig("result", "count").to_i
        break if all_ledgers.size >= count || ledgers.size < LEDGER_CHUNK_SIZE

        # Safety limit
        break if chunks_fetched >= MAX_LEDGER_CHUNKS

        offset += LEDGER_CHUNK_SIZE
      end

      # Store ledger snapshot
      kraken_account.upsert_ledger_snapshot!(all_ledgers)

      stats["ledger_entries_found"] = all_ledgers.size

      persist_stats!

      Rails.logger.info "KrakenItem::Importer - Imported #{all_ledgers.size} ledger entries"
    rescue => e
      Rails.logger.error "KrakenItem::Importer - Failed to import ledger: #{e.message}"
      register_error(e, context: "ledger_import")
    end

    def calculate_fiat_cash_from_balance(balance_response)
      return 0 unless balance_response.is_a?(Hash) && balance_response["result"].is_a?(Hash)

      total_cash = 0

      balance_response["result"].each do |asset_code, balance_data|
        balance = balance_data.is_a?(Hash) ? balance_data["balance"] : balance_data
        next if balance.to_d.zero?

        # Check if this is a fiat currency (ZEUR, ZUSD, etc.)
        normalized = asset_code.gsub(/^Z/, "").gsub(/\..*/, "")

        next unless FIAT_CURRENCIES.include?(normalized)

        # Convert to USD (simplified - would need real exchange rates)
        case normalized
        when "EUR"
          total_cash += balance.to_d * 1.05
        when "GBP"
          total_cash += balance.to_d * 1.27
        when "JPY"
          total_cash += balance.to_d / 150
        when "CAD"
          total_cash += balance.to_d * 0.70
        when "AUD"
          total_cash += balance.to_d * 0.62
        else
          total_cash += balance.to_d
        end
      end

      total_cash
    end

    def calculate_ledger_start_time(kraken_account)
      # Use sync_start_date if specified
      if kraken_account.sync_start_date.present?
        return kraken_account.sync_start_date.to_time.to_i
      end

      # For incremental sync, go back 7 days from last sync
      # Only if we've already done an initial sync (have existing ledger entries)
      if kraken_account.last_ledger_sync.present? && kraken_account.raw_ledger_payload.to_a.any?
        return (kraken_account.last_ledger_sync - 7.days).to_i
      end

      # Default: fetch last 90 days for initial sync (no existing entries yet)
      90.days.ago.to_i
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
