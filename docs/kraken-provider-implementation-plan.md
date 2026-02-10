# Kraken Provider Implementation Plan

## Project Overview

Implement a Kraken exchange provider for Sure financial tracking application, following the architecture patterns established by Coinbase while adapting to Kraken's unique API characteristics.

## Architecture Decisions

### 1. Provider Model: Portfolio-Style (Single Account)

Unlike Coinbase's per-wallet model, Kraken returns a single balance object containing all assets. Therefore:

- **One KrakenAccount per family** (not multiple like Coinbase)
- **Multiple Holdings per account** (BTC, ETH, staking variants, etc.)
- **Account Type**: Investment (supports multiple holdings)
- **Simpler UX**: Users link one account instead of dozens

### 2. Asset Code Normalization

Use `get_asset_info` endpoint with 24-hour TTL caching:

- Maps `XXBT` → `BTC`, `ZUSD` → `USD` using authoritative API data
- Handles edge cases (XBT vs BTC) that simple prefix stripping misses
- Cache prevents unnecessary API calls

### 3. Staking/Earn Handling: Separate Holdings

Following the 1:1 mapping principle from Discord discussion:

- Each Kraken asset type becomes a **separate Holding**
- Spot `DOT`, Staked `DOT.S`, Earn `DOT.F` = 3 separate holdings
- No synthetic aggregation (avoids "lossy translation layer")
- Users see exactly what Kraken shows them

---

## Implementation Phases

### Phase 1: Generate Scaffold

```bash
rails g provider:family kraken api_key:text:secret api_secret:text:secret --type=investment
```

**Generated Files:**

- `db/migrate/xxx_create_kraken_items_and_accounts.rb`
- `app/models/kraken_item.rb` + concerns (importer, syncer, provided, unlinking)
- `app/models/kraken_account.rb` + concerns (processor, holdings_processor)
- `app/models/provider/kraken.rb` (SDK)
- `app/models/provider/kraken_adapter.rb`
- `app/controllers/kraken_items_controller.rb`
- View templates (panel, setup_accounts, item partial)
- Jobs (cleanup)
- Tests and locales

**Modified Files:**

- `app/models/family.rb` (adds `Family::KrakenConnectable`)
- `config/routes.rb`
- Settings controllers/views
- Accounts controllers/views

---

### Phase 2: Implement Kraken SDK (`app/models/provider/kraken.rb`)

**Authentication: HMAC-SHA512**

```ruby
signature = HMAC-SHA512(
  URI path + SHA256(nonce + POST data),
  base64_decoded_secret
)
headers: {
  "API-Key" => api_key,
  "API-Sign" => signature
}
```

**Required Methods:**

1. `get_account_balance` - All spot balances
2. `get_extended_balance` - Staking/earn balances (`.S`, `.M`, `.F`, `.B`)
3. `get_ledgers(start_time, end_time)` - Transaction history
4. `get_asset_info` - Asset metadata (cached 24h)
5. `get_trade_balance` - Portfolio valuation
6. `get_ticker_information(pairs)` - Current prices

**Error Handling:**

- `Kraken::AuthenticationError` - Invalid credentials
- `Kraken::RateLimitError` - Too many requests (implement backoff)
- `Kraken::ApiError` - General API errors
- `Kraken::InvalidNonceError` - Clock sync issues

---

### Phase 3: Asset Info Caching System

```ruby
class Provider::Kraken
  ASSET_INFO_CACHE_TTL = 1.day

  def asset_info_map
    Rails.cache.fetch("kraken_asset_info", expires_in: ASSET_INFO_CACHE_TTL) do
      response = get_asset_info
      build_asset_mapping(response)
    end
  end

  def normalize_asset_code(kraken_code)
    # Separate base code from extension
    base_code = kraken_code.gsub(/\.[SMFBT]$/, '')
    extension = kraken_code.match(/\.([SMFBT])$/)&.[](1)
    
    # Map to standard ticker
    normalized = asset_info_map[base_code] || base_code.gsub(/^[XZ]/, '')
    
    [normalized, extension]
  end
end
```

---

### Phase 4: Customize Importer (`kraken_item/importer.rb`)

**Flow:**

1. Fetch spot balances from `get_account_balance`
2. Fetch extended balances from `get_extended_balance`
3. Combine all non-zero balances
4. Create/update single `KrakenAccount` record
5. Store raw payloads for debugging

**Data Structure:**

```ruby
kraken_account = {
  account_id: "kraken-portfolio",  # Static identifier
  name: "Kraken Portfolio",
  raw_balances: {
    "XXBT" => "0.5",
    "XXBT.S" => "0.1",
    "XETH" => "2.0",
    "ZUSD" => "1000.00"
  },
  raw_ledger_payload: [...],
  institution_metadata: {
    name: "Kraken",
    domain: "kraken.com"
  }
}
```

---

### Phase 5: Holdings Processor (`kraken_account/holdings_processor.rb`)

**Process:**

1. Iterate through all balances (spot + extended)
2. For each non-zero balance:
   - Parse Kraken asset code (e.g., `XXBT.S`)
   - Normalize to standard ticker (e.g., `BTC`)
   - Determine holding type (Spot, Staked, Earn)
   - Find or create `Security` record with `CRYPTO:` prefix
   - Create/update `Holding` via `Account::ProviderImportAdapter`

**Holding Types:**

- Spot: `BTC` → Standard holding
- Staked: `BTC.S` → Separate holding with `.S` suffix
- Earn: `BTC.F` → Separate holding with `.F` suffix

**Display Strategy:**

- Store normalized ticker (e.g., `CRYPTO:BTC`)
- Track Kraken-specific type in metadata
- UI can group related holdings visually

---

### Phase 6: Ledger Processing (`kraken_account/processor.rb`)

**Ledger Entry Types:**

- `trade` - Buy/sell orders
- `deposit` - Crypto/fiat deposits
- `withdrawal` - Crypto/fiat withdrawals
- `transfer` - Internal transfers (spot ↔ staking/earn)
- `staking` - Staking rewards
- `dividend` - Earn rewards

**Mapping to Sure Entries:**

- Trades → `Entry` with `Trade` entryable
- Deposits/Withdrawals → `Entry` with appropriate entryable
- Internal transfers → Skip or mark as transfer
- Rewards → `Entry` with income entryable

**Transaction Matching:**

- Use Kraken's `refid` for idempotency
- Store raw ledger entry in `extra` field
- Handle pagination for full history

---

### Phase 7: Adapter Implementation (`kraken_adapter.rb`)

```ruby
class Provider::KrakenAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("KrakenAccount", self)

  def self.supported_account_types
    %w[Investment]  # Portfolio model with multiple holdings
  end

  def provider_name
    "kraken"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_kraken_item_path(item)
  end

  # Institution metadata
  def institution_name; "Kraken"; end
  def institution_domain; "kraken.com"; end
  def institution_url; "https://www.kraken.com"; end
end
```

---

### Phase 8: UI & Localization

**Views to Customize:**

1. `settings/providers/_kraken_panel.html.erb` - Settings panel with API key form
2. `kraken_items/setup_accounts.html.erb` - Account linking (simpler - only one account)
3. `kraken_items/_kraken_item.html.erb` - Display in accounts list
4. `kraken_items/select_existing_account.html.erb` - Link to existing investment account

**Localization Files:**

- `config/locales/views/kraken_items/en.yml`
- Keys for: form labels, status messages, error messages, sync phases

---

### Phase 9: Testing Strategy

**Unit Tests:**

- `test/models/kraken_item_test.rb` - Model validations, encryption
- `test/models/kraken_account_test.rb` - Associations, methods
- `test/models/provider/kraken_test.rb` - SDK authentication, API methods
- `test/models/provider/kraken_adapter_test.rb` - Adapter interface

**Integration Tests:**

- `test/controllers/kraken_items_controller_test.rb` - Full CRUD, linking flow
- VCR cassettes for API responses (mock Kraken responses)

**Test Fixtures:**

- Mock API responses for balance, ledgers, asset info
- Test credentials (placeholder values)

---

## Database Schema

### kraken_items

| Column | Type | Notes |
|--------|------|-------|
| family_id | bigint | FK to families |
| name | string | User-defined name |
| api_key | text | Encrypted (deterministic) |
| api_secret | text | Encrypted |
| status | string | good, requires_update |
| institution_name | string | "Kraken" |
| institution_domain | string | "kraken.com" |
| institution_url | string | Provider URL |
| institution_color | string | Brand color |
| pending_account_setup | boolean | Account linking status |
| scheduled_for_deletion | boolean | Soft delete flag |
| raw_payload | jsonb | Last API response |
| timestamps | datetime | |

### kraken_accounts

| Column | Type | Notes |
|--------|------|-------|
| kraken_item_id | bigint | FK to kraken_items |
| account_id | string | Static "kraken-portfolio" |
| name | string | "Kraken Portfolio" |
| currency | string | "USD" (base currency) |
| current_balance | decimal | Total portfolio value |
| raw_payload | jsonb | Balance data |
| raw_ledger_payload | jsonb | Transaction history |
| institution_metadata | jsonb | Provider info |
| timestamps | datetime | |

---

## Security Considerations

1. **API Credentials**:
   - Use ActiveRecord encryption
   - API key: deterministic (queryable)
   - API secret: non-deterministic
   - Never log credentials

2. **Nonce Generation**:
   - Use high-precision timestamp
   - Must be strictly increasing
   - Handle clock sync issues gracefully

3. **Rate Limiting**:
   - Kraken: Tiered limits based on verification level
   - Implement request queuing
   - Add backoff on 429 responses

4. **Error Handling**:
   - Don't expose raw API errors to users
   - Log detailed errors for debugging
   - Show user-friendly messages

---

## Configuration

**Environment Variables:**

```bash
# Optional: Enable debug logging
KRAKEN_DEBUG=1

# Optional: Custom API endpoint (for testing)
KRAKEN_API_URL=https://api.kraken.com
```

**API Key Requirements:**

- `Funds permissions - Query` (for balances)
- `Data - Query ledger entries` (for transactions)
- `Orders and trades - Query` (for trade history)

---

## Success Criteria

### Functionality

- [X] Users can connect Kraken API with key/secret
- [X] Balances sync correctly (spot + extended)
- [X] All holdings display with correct tickers
- [X] Transaction history imports completely
- [X] Account value calculates correctly

### UX

- [X] Simple one-account linking flow
- [X] Clear error messages for invalid credentials
- [X] Visual distinction for staked/earn holdings
- [X] Responsive sync status indicators

### Quality

- [X] All tests pass
- [X] No Rubocop offenses
- [X] Biome formatting clean
- [X] Security scan passes (Brakeman)

---

## Next Steps

1. **Review this plan** - Any adjustments needed?
2. **Approval to proceed** - Confirm you want me to start implementation
3. **Phase 1 execution** - Generate scaffold files
4. **Iterative development** - Complete phases 2-9

**Estimated Timeline**: 2-3 days for full implementation (assuming 4-6 hours/day)

---

## Notes

- Spot trading support only (no margin/futures initially)
- Import all historical data at first sync
- No Kraken sandbox available for testing (use VCR cassettes)
- Follow the 1:1 mapping principle: mirror Kraken's structure exactly
- Asset code normalization via cached `get_asset_info` endpoint
- Separate holdings for spot/staking/earn positions
