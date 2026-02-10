# frozen_string_literal: true

class KrakenItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret, deterministic: true
  end

  validates :name, presence: true
  validates :api_key, presence: true, on: :create
  validates :api_secret, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :kraken_accounts, dependent: :destroy
  has_many :accounts, through: :kraken_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def syncer
    KrakenItem::Syncer.new(self)
  end

  # Get Kraken provider instance with credentials
  # @return [Provider::Kraken, nil]
  def kraken_provider
    return nil unless credentials_configured?

    @kraken_provider ||= Provider::Kraken.new(
      api_key: api_key,
      api_secret: api_secret
    )
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Override syncing? to include background activities fetch
  def syncing?
    super || kraken_accounts.where(activities_fetch_pending: true).exists?
  end

  # Import data from provider API
  def import_latest_kraken_data(sync: nil)
    provider = kraken_provider
    unless provider
      Rails.logger.error "KrakenItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("kraken_items.errors.provider_not_configured")
    end

    KrakenItem::Importer.new(self, kraken_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "KrakenItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if kraken_accounts.empty?

    results = []
    linked_kraken_accounts.includes(account_provider: :account).each do |kraken_account|
      begin
        result = KrakenAccount::Processor.new(kraken_account).process
        results << { kraken_account_id: kraken_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "KrakenItem #{id} - Failed to process account #{kraken_account.id}: #{e.message}"
        results << { kraken_account_id: kraken_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Schedule sync jobs for all linked accounts
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "KrakenItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_kraken_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_kraken_accounts
    kraken_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_kraken_accounts
    kraken_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("kraken_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("kraken_items.sync_status.synced", count: linked_count)
    else
      I18n.t("kraken_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    kraken_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    kraken_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    kraken_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    kraken_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("kraken_items.institution_summary.none")
    else
      I18n.t("kraken_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end
end
