# frozen_string_literal: true

# Processes Kraken ledger entries to create trades, transactions, and transfers.
# Kraken ledger types: trade, deposit, withdrawal, transfer, staking, dividend, etc.
class KrakenAccount::LedgerProcessor
  include KrakenAccount::DataHelpers

  # Map Kraken ledger types to Sure activity labels
  LEDGER_TYPE_TO_LABEL = {
    "trade" => "Trade",
    "deposit" => "Deposit",
    "withdrawal" => "Withdrawal",
    "transfer" => "Transfer",
    "staking" => "Staking",
    "reward" => "Reward",
    "dividend" => "Dividend",
    "margin" => "Margin",
    "rollover" => "Rollover",
    "spend" => "Spend",
    "receive" => "Receive",
    "adjustment" => "Adjustment"
  }.freeze

  # Ledger types that result in Trade records
  TRADE_TYPES = %w[trade].freeze

  # Ledger types that are staking/earn rewards (income)
  REWARD_TYPES = %w[staking dividend].freeze

  # Ledger types that are cash movements
  CASH_TYPES = %w[deposit withdrawal transfer].freeze

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    ledger_data = @kraken_account.raw_ledger_payload
    return { trades: 0, transactions: 0, rewards: 0 } if ledger_data.blank?

    Rails.logger.info "KrakenAccount::LedgerProcessor - Processing #{ledger_data.size} ledger entries"

    @trades_count = 0
    @transactions_count = 0
    @rewards_count = 0

    # Group ledger entries by refid (Kraken groups related entries by refid)
    # e.g., a trade has two entries: one for the asset bought, one for the asset sold
    grouped_entries = group_entries_by_refid(ledger_data)

    grouped_entries.each do |refid, entries|
      process_entry_group(refid, entries)
    rescue => e
      Rails.logger.error "KrakenAccount::LedgerProcessor - Failed to process entry group #{refid}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    { trades: @trades_count, transactions: @transactions_count, rewards: @rewards_count }
  end

  private

    def account
      @kraken_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def kraken_provider
      @kraken_provider ||= @kraken_account.kraken_item&.kraken_provider
    end

    # Group ledger entries by refid
    def group_entries_by_refid(ledger_data)
      grouped = Hash.new { |h, k| h[k] = [] }
      ledger_data.each do |entry|
        refid = entry.is_a?(Hash) ? entry["refid"] : entry[:refid]
        grouped[refid] << entry if refid.present?
      end
      grouped
    end

    # Process a group of entries with the same refid
    def process_entry_group(refid, entries)
      return if entries.empty?

      # Get the main entry (usually the first one)
      main_entry = entries.first.with_indifferent_access
      ledger_type = main_entry[:type]&.downcase

      return if ledger_type.blank?

      Rails.logger.info "KrakenAccount::LedgerProcessor - Processing entry group: refid=#{refid}, type=#{ledger_type}"

      case ledger_type
      when *TRADE_TYPES
        process_trade(refid, entries)
      when *REWARD_TYPES
        process_reward(refid, main_entry)
      when *CASH_TYPES
        process_cash_entry(refid, main_entry, ledger_type)
      else
        Rails.logger.debug "KrakenAccount::LedgerProcessor - Skipping unhandled ledger type: #{ledger_type}"
      end
    end

    # Process a trade entry (has two sides: buy and sell)
    def process_trade(refid, entries)
      return unless entries.size >= 2

      # Separate buy and sell sides
      buy_entry = nil
      sell_entry = nil

      entries.each do |entry|
        data = entry.with_indifferent_access
        amount = data[:amount].to_d
        if amount > 0
          buy_entry = data
        else
          sell_entry = data
        end
      end

      return unless buy_entry && sell_entry

      # Get asset info
      buy_asset = normalize_asset_code(buy_entry[:asset])
      sell_asset = normalize_asset_code(sell_entry[:asset])

      buy_qty = buy_entry[:amount].to_d.abs
      sell_qty = sell_entry[:amount].to_d.abs

      # Determine which side is the security being traded
      # Usually the non-fiat asset is the security
      if fiat_currency?(sell_asset)
        # Buying crypto with fiat (e.g., buy BTC with USD)
        process_buy_trade(refid, buy_entry, sell_entry, buy_asset, buy_qty, sell_qty)
      elsif fiat_currency?(buy_asset)
        # Selling crypto for fiat (e.g., sell BTC for USD)
        process_sell_trade(refid, buy_entry, sell_entry, sell_asset, sell_qty, buy_qty)
      else
        # Crypto-to-crypto trade (e.g., trade BTC for ETH)
        process_crypto_trade(refid, buy_entry, sell_entry)
      end
    end

    def process_buy_trade(refid, buy_entry, sell_entry, ticker, qty, cost_amount)
      security = resolve_security(ticker)
      return unless security

      price = cost_amount / qty if qty > 0
      date = parse_timestamp(buy_entry[:time])
      currency = normalize_asset_code(sell_entry[:asset])

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing buy trade: #{ticker} qty=#{qty} price=#{price}"

      result = import_adapter.import_trade(
        external_id: "kraken_#{refid}",
        security: security,
        quantity: qty,
        price: price,
        amount: -cost_amount, # Negative because money goes out
        currency: currency,
        date: date,
        name: "Buy #{ticker}",
        source: "kraken",
        activity_label: "Buy"
      )
      @trades_count += 1 if result
    end

    def process_sell_trade(refid, buy_entry, sell_entry, ticker, qty, proceeds_amount)
      security = resolve_security(ticker)
      return unless security

      price = proceeds_amount / qty if qty > 0
      date = parse_timestamp(sell_entry[:time])
      currency = normalize_asset_code(buy_entry[:asset])

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing sell trade: #{ticker} qty=#{qty} price=#{price}"

      result = import_adapter.import_trade(
        external_id: "kraken_#{refid}",
        security: security,
        quantity: -qty, # Negative because we're selling
        price: price,
        amount: proceeds_amount,
        currency: currency,
        date: date,
        name: "Sell #{ticker}",
        source: "kraken",
        activity_label: "Sell"
      )
      @trades_count += 1 if result
    end

    def process_crypto_trade(refid, buy_entry, sell_entry)
      # Crypto-to-crypto trades are complex - for now, log and skip
      # This could be implemented as two separate entries in the future
      Rails.logger.info "KrakenAccount::LedgerProcessor - Skipping crypto-to-crypto trade: #{refid}"
    end

    # Process staking/earn rewards as income
    def process_reward(refid, entry)
      ticker = normalize_asset_code(entry[:asset])
      return if ticker.blank?

      qty = entry[:amount].to_d.abs
      return if qty.zero?

      security = resolve_security(ticker)
      return unless security

      date = parse_timestamp(entry[:time])
      reward_type = entry[:type]&.downcase
      label = reward_type == "staking" ? "Staking" : "Dividend"

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing #{label}: #{ticker} qty=#{qty}"

      # Import as a transaction with the security
      result = import_adapter.import_transaction(
        external_id: "kraken_#{refid}",
        amount: 0, # Rewards have no cash impact
        currency: account.currency,
        date: date,
        name: "#{label} - #{ticker}",
        source: "kraken",
        investment_activity_label: label
      )
      @rewards_count += 1 if result
    end

    # Process cash entries (deposits, withdrawals, transfers)
    def process_cash_entry(refid, entry, entry_type)
      ticker = normalize_asset_code(entry[:asset])
      return if ticker.blank?

      amount = entry[:amount].to_d
      return if amount.zero?

      date = parse_timestamp(entry[:time])
      label = LEDGER_TYPE_TO_LABEL[entry_type] || entry_type.capitalize

      # Skip internal transfers (they have matching in/out entries)
      if entry_type == "transfer"
        Rails.logger.debug "KrakenAccount::LedgerProcessor - Skipping transfer entry: #{refid}"
        return
      end

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing #{label}: #{ticker} amount=#{amount}"

      result = import_adapter.import_transaction(
        external_id: "kraken_#{refid}",
        amount: amount,
        currency: ticker,
        date: date,
        name: "#{label} - #{ticker}",
        source: "kraken",
        investment_activity_label: label
      )
      @transactions_count += 1 if result
    end

    def resolve_security(ticker)
      # Use CRYPTO: prefix for crypto securities
      crypto_ticker = ticker.include?(":") ? ticker : "CRYPTO:#{ticker}"

      begin
        Security::Resolver.new(crypto_ticker).resolve
      rescue => e
        Rails.logger.debug(
          "KrakenAccount::LedgerProcessor - Resolver failed for #{crypto_ticker}: #{e.message}; creating offline security"
        )

        Security.find_or_create_by(ticker: crypto_ticker) do |security|
          security.name = ticker
          security.exchange_operating_mic = "XKRK"
          security.offline = true if security.respond_to?(:offline=)
        end
      end
    end

    def normalize_asset_code(kraken_code)
      return nil if kraken_code.blank?
      return kraken_code if kraken_provider.nil?

      normalized, _ = kraken_provider.normalize_asset_code(kraken_code)
      normalized
    end

    def fiat_currency?(code)
      %w[USD EUR GBP CAD AUD JPY CHF].include?(code&.upcase)
    end

    def parse_timestamp(timestamp)
      return Date.current if timestamp.blank?

      # Kraken uses Unix timestamps
      if timestamp.is_a?(Numeric)
        Time.at(timestamp).to_date
      else
        Date.parse(timestamp.to_s) rescue Date.current
      end
    end
end
