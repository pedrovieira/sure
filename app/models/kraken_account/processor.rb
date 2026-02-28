# frozen_string_literal: true

class KrakenAccount::Processor
  include KrakenAccount::DataHelpers

  attr_reader :kraken_account

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    account = kraken_account.current_account
    return unless account

    Rails.logger.info "KrakenAccount::Processor - Processing account #{kraken_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process holdings
    holdings_count = kraken_account.raw_holdings_payload&.size || 0
    Rails.logger.info "KrakenAccount::Processor - Holdings payload has #{holdings_count} items"

    if kraken_account.raw_holdings_payload.present?
      Rails.logger.info "KrakenAccount::Processor - Processing holdings..."
      KrakenAccount::HoldingsProcessor.new(kraken_account).process
    else
      Rails.logger.warn "KrakenAccount::Processor - No holdings payload to process"
    end

    # Process ledger entries (trades, transfers, rewards, etc.)
    ledger_count = kraken_account.raw_ledger_payload&.size || 0
    Rails.logger.info "KrakenAccount::Processor - Ledger payload has #{ledger_count} items"

    if kraken_account.raw_ledger_payload.present?
      Rails.logger.info "KrakenAccount::Processor - Processing ledger entries..."
      KrakenAccount::LedgerProcessor.new(kraken_account).process
    else
      Rails.logger.warn "KrakenAccount::Processor - No ledger payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "KrakenAccount::Processor - Broadcast sync complete for account #{account.id}"

    { holdings_processed: holdings_count > 0, ledger_processed: ledger_count > 0 }
  end

  private

    def update_account_balance(account)
      # Calculate total balance and cash balance from provider data
      total_balance = calculate_total_balance
      cash_balance = calculate_cash_balance

      Rails.logger.info "KrakenAccount::Processor - Balance update: total=#{total_balance}, cash=#{cash_balance}"

      # Update the cached fields on the account
      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: kraken_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(total_balance)
    end

    def calculate_total_balance
      # For Kraken, use the API's equity balance (eb) directly
      # This already includes all holdings + cash in the account
      if kraken_account.current_balance.present?
        Rails.logger.info "KrakenAccount::Processor - Using Kraken equity balance: #{kraken_account.current_balance}"
        kraken_account.current_balance
      else
        # Fallback to holdings + cash calculation
        holdings_value = calculate_holdings_value
        cash_value = kraken_account.cash_balance || 0
        holdings_value + cash_value
      end
    end

    def calculate_cash_balance
      # Use provider's cash_balance directly
      # Note: Can be negative for margin accounts
      cash = kraken_account.cash_balance
      Rails.logger.info "KrakenAccount::Processor - Cash balance from API: #{cash.inspect}"
      cash || BigDecimal("0")
    end

    def calculate_holdings_value
      holdings_data = kraken_account.raw_holdings_payload || []
      return 0 if holdings_data.empty?

      holdings_data.sum do |holding|
        data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
        # TODO: Customize field names based on your provider's format
        units = parse_decimal(data[:units] || data[:quantity]) || 0
        price = parse_decimal(data[:price]) || 0
        units * price
      end
    end
end
