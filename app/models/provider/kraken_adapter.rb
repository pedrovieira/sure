class Provider::KrakenAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("KrakenAccount", self)

  # Kraken supports Investment accounts (single portfolio with multiple holdings)
  def self.supported_account_types
    %w[Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_kraken?

    [ {
      key: "kraken",
      name: "Kraken",
      description: "Link to your Kraken exchange portfolio",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_kraken_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_kraken_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "kraken"
  end

  # Build a Kraken provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Kraken, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    kraken_item = family.kraken_items.where.not(api_key: nil).first
    return nil unless kraken_item&.credentials_configured?

    Provider::Kraken.new(
      api_key: kraken_item.api_key,
      api_secret: kraken_item.api_secret
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_kraken_item_path(item)
  end

  def item
    provider_account.kraken_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Kraken account #{provider_account.id}: #{url}")
      end
    end

    domain || "kraken.com"
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name || "Kraken"
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url || "https://www.kraken.com"
  end

  def institution_color
    item&.institution_color || "#5741D7" # Kraken purple
  end
end
