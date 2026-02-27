#!/usr/bin/env ruby
# Fix existing Kraken ledger data by re-importing with correct refid

require_relative "config/environment"

puts "=== REPAIRING KRAKEN LEDGER DATA ==="

kraken_item = KrakenItem.first
if kraken_item.nil?
  puts "ERROR: No KrakenItem found!"
  exit 1
end

kraken_account = kraken_item.kraken_accounts.first
if kraken_account.nil?
  puts "ERROR: No KrakenAccount found!"
  exit 1
end

# Get provider
provider = kraken_item.kraken_provider
unless provider
  puts "ERROR: No provider configured!"
  exit 1
end

puts "Fetching fresh ledger data from Kraken API..."

# Fetch fresh ledger data
all_ledgers = []
offset = 0
chunks = 0
max_chunks = 10

loop do
  response = provider.get_ledgers(offset: offset)
  chunks += 1

  ledgers = response.dig("result", "ledger") || {}
  break if ledgers.empty?

  # Convert to array preserving internal refid (the trade reference)
  ledgers.each do |ledger_id, ledger_data|
    all_ledgers << ledger_data.merge("ledger_id" => ledger_id)
  end

  count = response.dig("result", "count").to_i
  break if all_ledgers.size >= count || ledgers.size < 50
  break if chunks >= max_chunks

  offset += 50
end

puts "Fetched #{all_ledgers.size} ledger entries"

# Update the ledger snapshot
kraken_account.upsert_ledger_snapshot!(all_ledgers)
puts "Updated ledger snapshot with correct refid fields"

# Now re-run the processor
puts "\nRe-processing ledger entries..."

# Clear existing Kraken entries first
account = kraken_account.current_account
if account
  old_count = account.entries.where(source: "kraken").count
  puts "Removing #{old_count} existing Kraken entries..."
  account.entries.where(source: "kraken").destroy_all
  puts "Removed existing entries"
end

# Process the fixed ledger
processor = KrakenAccount::LedgerProcessor.new(kraken_account)
result = processor.process

puts "\n=== RESULT ==="
puts "Trades created: #{result[:trades]}"
puts "Transactions created: #{result[:transactions]}"
puts "Rewards created: #{result[:rewards]}"

# Show new entries
puts "\n=== NEW ENTRIES ==="
account.entries.where(source: "kraken").order(date: :desc).each do |entry|
  puts "- #{entry.date}: #{entry.name} (#{entry.entryable_type})"
  puts "  #{entry.amount} #{entry.currency} | #{entry.external_id}"
  if entry.entryable.is_a?(Trade)
    trade = entry.entryable
    puts "  Trade: #{trade.qty} #{trade.security&.ticker} @ #{trade.price}"
  end
end

puts "\nDone!"
