# frozen_string_literal: true

class KrakenAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_holdings_payload
    encrypts :raw_ledger_payload
  end

  belongs_to :kraken_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Create or update the AccountProvider link for this kraken_account
  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "KrakenAccount", provider_id: id)
      .tap do |provider|
        provider.account = acct
        provider.save!
      end
  rescue => e
    Rails.logger.warn("Kraken provider link ensure failed for #{id}: #{e.class} - #{e.message}")
    nil
  end

  # Update account from Kraken portfolio data
  # @param portfolio_data [Hash] Data from Kraken API
  def upsert_from_kraken!(portfolio_data)
    data = portfolio_data.with_indifferent_access

    update!(
      kraken_account_id: data[:account_id] || "kraken-portfolio",
      name: data[:name] || "Kraken Portfolio",
      current_balance: parse_decimal(data[:current_balance]) || 0,
      currency: data[:currency] || "USD",
      cash_balance: parse_decimal(data[:cash_balance]) || 0,
      account_status: data[:account_status] || "active",
      account_type: data[:account_type] || "investment",
      provider: "kraken",
      institution_metadata: data[:institution_metadata],
      raw_payload: portfolio_data
    )
  end

  # Store holdings snapshot from Kraken balance data
  # @param holdings_data [Array] Holdings data from Kraken
  def upsert_holdings_snapshot!(holdings_data)
    return if holdings_data.blank?

    update!(
      raw_holdings_payload: holdings_data,
      last_holdings_sync: Time.current
    )
  end

  # Store ledger/transaction snapshot from Kraken
  # @param ledger_data [Array] Ledger entries from Kraken
  def upsert_ledger_snapshot!(ledger_data)
    return if ledger_data.blank?

    update!(
      raw_ledger_payload: ledger_data,
      last_ledger_sync: Time.current
    )
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Kraken account #{id}, defaulting to USD")
    end
end
