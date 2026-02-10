# frozen_string_literal: true

class KrakenItemsController < ApplicationController
  before_action :set_kraken_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @kraken_items = Current.family.kraken_items.ordered
  end

  def show
  end

  def new
    @kraken_item = Current.family.kraken_items.build
  end

  def edit
  end

  def create
    @kraken_item = Current.family.kraken_items.build(kraken_item_params)
    @kraken_item.name ||= "Kraken Connection"

    if @kraken_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Kraken.")
        @kraken_items = Current.family.kraken_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "kraken-providers-panel",
            partial: "settings/providers/kraken_panel",
            locals: { kraken_items: @kraken_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @kraken_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "kraken-providers-panel",
          partial: "settings/providers/kraken_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @kraken_item.update(kraken_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Kraken configuration.")
        @kraken_items = Current.family.kraken_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "kraken-providers-panel",
            partial: "settings/providers/kraken_panel",
            locals: { kraken_items: @kraken_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @kraken_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "kraken-providers-panel",
          partial: "settings/providers/kraken_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @kraken_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Kraken connection for deletion.")
  end

  def sync
    unless @kraken_item.syncing?
      @kraken_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    kraken_item = Current.family.kraken_items.first
    unless kraken_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    kraken_item.sync_later unless kraken_item.syncing?
    redirect_to select_accounts_kraken_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    kraken_item = Current.family.kraken_items.first
    unless kraken_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @kraken_accounts = kraken_item.kraken_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def link_accounts
    kraken_item = Current.family.kraken_items.first
    unless kraken_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_kraken_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    kraken_item.kraken_accounts.where(id: selected_ids).find_each do |kraken_account|
      # Skip if already linked
      if kraken_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if kraken_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_kraken_account(kraken_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "KrakenItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      kraken_item.sync_later unless kraken_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_kraken_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @kraken_item = Current.family.kraken_items.first

    unless @kraken_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @kraken_accounts = @kraken_item.kraken_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    kraken_item = Current.family.kraken_items.first

    unless kraken_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    kraken_account = kraken_item.kraken_accounts.find(params[:kraken_account_id])

    if kraken_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    kraken_account.ensure_account_provider!(account)
    kraken_item.sync_later unless kraken_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @kraken_item.unlinked_kraken_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)

    if selected_accounts.empty?
      redirect_to setup_accounts_kraken_item_path(@kraken_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    selected_accounts.each do |kraken_account_id|
      kraken_account = @kraken_item.kraken_accounts.find_by(id: kraken_account_id)
      next unless kraken_account
      next if kraken_account.account_provider.present?

      # Create account as Crypto (Kraken accounts are always crypto exchange accounts)
      account = Current.family.accounts.create!(
        name: kraken_account.name,
        balance: kraken_account.current_balance || 0,
        currency: kraken_account.currency || "USD",
        accountable: Crypto.new
      )

      if account.persisted?
        kraken_account.ensure_account_provider!(account)
        created_count += 1

        # Process holdings immediately so user sees them right away
        begin
          KrakenAccount::HoldingsProcessor.new(kraken_account).process
        rescue => e
          Rails.logger.error("Failed to process holdings for #{kraken_account.id}: #{e.message}")
        end
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "KrakenItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @kraken_item.sync_later unless @kraken_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_kraken_item_path(@kraken_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_kraken_item
      @kraken_item = Current.family.kraken_items.find(params[:id])
    end

    def kraken_item_params
      params.require(:kraken_item).permit(
        :name,
        :sync_start_date,
        :api_key,
        :api_secret
      )
    end

    def link_kraken_account(kraken_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: kraken_account.name,
        balance: kraken_account.current_balance || 0,
        currency: kraken_account.currency || "USD",
        accountable: accountable_class.new
      )

      kraken_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_kraken(kraken_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: kraken_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (kraken_account.current_balance || 0),
        currency: kraken_account.currency || "USD",
        accountable: accountable_class.new(accountable_attrs)
      )
    end

    def infer_accountable_type(account_type, subtype = nil)
      case account_type&.downcase
      when "depository"
        "Depository"
      when "credit_card"
        "CreditCard"
      when "investment"
        "Investment"
      when "loan"
        "Loan"
      when "other_asset"
        "OtherAsset"
      when "other_liability"
        "OtherLiability"
      when "crypto"
        "Crypto"
      when "property"
        "Property"
      when "vehicle"
        "Vehicle"
      else
        "Depository"
      end
    end

    def validated_accountable_class(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type.constantize
    end
end
