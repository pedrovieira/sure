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

      # Parse all entries
      parsed_entries = entries.map { |e| parse_entry(e) }

      # Separate positive (received) and negative (spent) amounts
      received_entries = parsed_entries.select { |e| e[:amount] > 0 }
      spent_entries = parsed_entries.select { |e| e[:amount] < 0 }

      return unless received_entries.any? && spent_entries.any?

      # For a buy: received = crypto, spent = fiat/currency
      # For a sell: received = fiat/currency, spent = crypto
      # Determine which is which by checking if it's a fiat currency

      received_crypto = received_entries.find { |e| !fiat_currency?(e[:asset]) }
      received_fiat = received_entries.find { |e| fiat_currency?(e[:asset]) }
      spent_crypto = spent_entries.find { |e| !fiat_currency?(e[:asset]) }
      spent_fiat = spent_entries.find { |e| fiat_currency?(e[:asset]) }

      if received_crypto && spent_fiat
        # Buy trade: received crypto, spent fiat
        process_buy_trade(refid, received_crypto, spent_fiat, parsed_entries)
      elsif spent_crypto && received_fiat
        # Sell trade: spent crypto, received fiat
        process_sell_trade(refid, spent_crypto, received_fiat, parsed_entries)
      else
        # Crypto-to-crypto trade
        process_crypto_trade(refid, received_entries, spent_entries)
      end
    end

    def parse_entry(entry)
      data = entry.with_indifferent_access
      {
        asset: normalize_asset_code(data[:asset]),
        amount: data[:amount].to_d,
        fee: data[:fee].to_d,
        time: data[:time],
        refid: data[:refid]
      }
    end

    # Process a buy trade (received crypto, spent fiat)
    # Fees can be in either the crypto or fiat (or both)
    def process_buy_trade(refid, crypto_entry, fiat_entry, all_entries)
      ticker = crypto_entry[:asset]
      security = resolve_security(ticker)
      return unless security

      # Calculate net amounts
      # Gross crypto received
      gross_qty = crypto_entry[:amount].to_d.abs
      # Fee in crypto (if any)
      crypto_fee = crypto_entry[:fee].to_d.abs
      # Net crypto after fee
      net_qty = gross_qty - crypto_fee

      # Gross fiat spent (negative amount)
      gross_cost = fiat_entry[:amount].to_d.abs
      # Fee in fiat (if any)
      fiat_fee = fiat_entry[:fee].to_d.abs
      # Total cost including fee
      total_cost = gross_cost + fiat_fee

      # Calculate price per unit
      price = total_cost / net_qty if net_qty > 0

      date = parse_timestamp(crypto_entry[:time])
      currency = fiat_entry[:asset]

      # Build notes with fee information
      notes = build_fee_notes(crypto_fee: crypto_fee, crypto_ticker: ticker, fiat_fee: fiat_fee, fiat_ticker: currency)

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing BUY: #{ticker} qty=#{net_qty} (gross: #{gross_qty}, fee: #{crypto_fee}) cost=#{total_cost} #{currency}"

      # Import the trade
      result = import_adapter.import_trade(
        external_id: "kraken_#{refid}",
        security: security,
        quantity: net_qty,
        price: price,
        amount: -total_cost, # Negative because money goes out
        currency: currency,
        date: date,
        name: "Buy #{ticker}",
        source: "kraken",
        activity_label: "Buy",
        notes: notes
      )

      @trades_count += 1 if result
    end

    # Process a sell trade (spent crypto, received fiat)
    # Fees can be in either the crypto or fiat (or both)
    def process_sell_trade(refid, crypto_entry, fiat_entry, all_entries)
      ticker = crypto_entry[:asset]
      security = resolve_security(ticker)
      return unless security

      # Calculate net amounts
      # Gross crypto sold (negative amount)
      gross_qty = crypto_entry[:amount].to_d.abs
      # Fee in crypto (if any)
      crypto_fee = crypto_entry[:fee].to_d.abs
      # Net crypto after fee
      net_qty = gross_qty - crypto_fee

      # Gross fiat received
      gross_proceeds = fiat_entry[:amount].to_d.abs
      # Fee in fiat (if any)
      fiat_fee = fiat_entry[:fee].to_d.abs
      # Net proceeds after fee
      net_proceeds = gross_proceeds - fiat_fee

      # Calculate price per unit
      price = net_proceeds / gross_qty if gross_qty > 0

      date = parse_timestamp(crypto_entry[:time])
      currency = fiat_entry[:asset]

      # Build notes with fee information
      notes = build_fee_notes(crypto_fee: crypto_fee, crypto_ticker: ticker, fiat_fee: fiat_fee, fiat_ticker: currency)

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing SELL: #{ticker} qty=#{net_qty} (gross: #{gross_qty}, fee: #{crypto_fee}) proceeds=#{net_proceeds} #{currency}"

      # Import the trade
      result = import_adapter.import_trade(
        external_id: "kraken_#{refid}",
        security: security,
        quantity: -net_qty, # Negative because we're selling
        price: price,
        amount: net_proceeds,
        currency: currency,
        date: date,
        name: "Sell #{ticker}",
        source: "kraken",
        activity_label: "Sell",
        notes: notes
      )

      @trades_count += 1 if result
    end

    # Build fee notes string for trades
    # If fee is in the bought currency, it's already deducted from quantity
    # If fee is in the spending currency, it's included in the total cost
    def build_fee_notes(crypto_fee:, crypto_ticker:, fiat_fee:, fiat_ticker:)
      notes = []

      if crypto_fee > 0
        notes << "Fee: #{crypto_fee} #{crypto_ticker} deducted from quantity"
      end

      if fiat_fee > 0
        notes << "Fee: #{fiat_fee} #{fiat_ticker} included in total"
      end

      notes.join(". ")
    end

    def process_crypto_trade(refid, received_entries, spent_entries)
      # Crypto-to-crypto trades are complex - for now, log and skip
      Rails.logger.info "KrakenAccount::LedgerProcessor - Skipping crypto-to-crypto trade: #{refid}"
    end

    # Process staking/earn rewards as income
    # Single entry (not grouped like trades)
    # Example: {asset: "ADA.S", amount: "0.12410846", fee: "0.03102711", type: "staking"}
    def process_reward(refid, entry)
      data = entry.with_indifferent_access
      ticker = normalize_asset_code(data[:asset])
      return if ticker.blank?

      # Parse amounts
      gross_qty = data[:amount].to_d.abs
      fee = data[:fee].to_d.abs
      # Net reward after fee deduction
      net_qty = gross_qty - fee

      return if net_qty <= 0

      security = resolve_security(ticker)
      return unless security

      date = parse_timestamp(data[:time])
      reward_type = data[:type]&.downcase
      label = reward_type == "staking" ? "Staking" : "Dividend"

      # Build notes with fee information
      notes = if fee > 0
        "Gross reward: #{gross_qty} #{ticker}. Fee: #{fee} #{ticker} deducted. Net: #{net_qty} #{ticker}"
      else
        nil
      end

      Rails.logger.info "KrakenAccount::LedgerProcessor - Importing #{label}: #{ticker} qty=#{net_qty} (gross: #{gross_qty}, fee: #{fee})"

      # Import as a trade with zero cost basis (rewards are income)
      result = import_adapter.import_trade(
        external_id: "kraken_#{refid}",
        security: security,
        quantity: net_qty,
        price: 0, # Rewards have no purchase price
        amount: 0, # No cash outflow
        currency: account.currency,
        date: date,
        name: "#{label} - #{ticker}",
        source: "kraken",
        activity_label: label,
        notes: notes
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

      # Skip internal transfers
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
