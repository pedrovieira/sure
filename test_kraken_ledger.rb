#!/usr/bin/env ruby
# Test script to debug Kraken ledger processing

require_relative "config/environment"

# Find the Kraken account
kraken_item = KrakenItem.first
puts "KrakenItem: #{kraken_item&.id} - #{kraken_item&.name}"

if kraken_item.nil?
  puts "ERROR: No KrakenItem found!"
  exit 1
end

kraken_account = kraken_item.kraken_accounts.first
puts "KrakenAccount: #{kraken_account&.id} - #{kraken_account&.name}"

if kraken_account.nil?
  puts "ERROR: No KrakenAccount found!"
  exit 1
end

# Check if account is linked
account = kraken_account.current_account
puts "Linked Account: #{account&.id} - #{account&.name}"

if account.nil?
  puts "ERROR: KrakenAccount not linked to any Account!"
  exit 1
end

# Check ledger data
ledger_data = kraken_account.raw_ledger_payload
puts "\n=== LEDGER DATA ==="
puts "Total entries in ledger: #{ledger_data&.size || 0}"

if ledger_data.blank?
  puts "ERROR: No ledger data!"
  exit 1
end

# Group by refid like the processor does
grouped = Hash.new { |h, k| h[k] = [] }
ledger_data.each do |entry|
  refid = entry.is_a?(Hash) ? entry["refid"] : entry[:refid]
  grouped[refid] << entry if refid.present?
end

puts "Unique refid groups: #{grouped.size}"
puts "\n=== REFID GROUPS ==="

grouped.each do |refid, entries|
  types = entries.map { |e| e["type"] || e[:type] }.uniq
  assets = entries.map { |e| e["asset"] || e[:asset] }.uniq
  amounts = entries.map { |e| e["amount"] || e[:amount] }

  puts "\nRefid: #{refid}"
  puts "  Types: #{types.join(', ')}"
  puts "  Assets: #{assets.join(', ')}"
  puts "  Amounts: #{amounts.join(', ')}"
  puts "  Entry count: #{entries.size}"

  # Check if it's a trade
  if types.include?("trade")
    puts "  -> This is a TRADE"

    # Parse like the processor does
    parsed = entries.map do |e|
      data = e.with_indifferent_access
      {
        asset: data[:asset],
        amount: data[:amount].to_d,
        fee: data[:fee].to_d
      }
    end

    received = parsed.select { |e| e[:amount] > 0 }
    spent = parsed.select { |e| e[:amount] < 0 }

    puts "  -> Received entries: #{received.size}"
    received.each { |e| puts "     #{e[:asset]}: #{e[:amount]}" }

    puts "  -> Spent entries: #{spent.size}"
    spent.each { |e| puts "     #{e[:asset]}: #{e[:amount]}" }

    # Check asset normalization
    provider = kraken_item.kraken_provider
    if provider
      assets.each do |asset|
        normalized, ext = provider.normalize_asset_code(asset)
        puts "  -> Normalized #{asset} -> #{normalized} (ext: #{ext})"
      end
    end

    # Check if securities exist
    assets.each do |asset|
      next if %w[ZEUR ZUSD].include?(asset)

      provider = kraken_item.kraken_provider
      if provider
        normalized, _ = provider.normalize_asset_code(asset)
        ticker = "CRYPTO:#{normalized}"
        security = Security.find_by(ticker: ticker)
        puts "  -> Security lookup for #{ticker}: #{security ? 'FOUND' : 'NOT FOUND'}"
      end
    end
  end
end

puts "\n=== EXISTING ENTRIES ==="
kraken_entries = account.entries.where(source: "kraken")
puts "Total Kraken entries in account: #{kraken_entries.count}"

kraken_entries.each do |entry|
  puts "  - #{entry.date}: #{entry.name} (#{entry.entryable_type}) - #{entry.amount} #{entry.currency}"
  puts "    external_id: #{entry.external_id}"
  if entry.entryable.is_a?(Trade)
    puts "    trade: #{entry.entryable.qty} #{entry.entryable.security&.ticker} @ #{entry.entryable.price}"
  elsif entry.entryable.is_a?(Transaction)
    puts "    transaction: #{entry.entryable.investment_activity_label}"
  end
end

puts "\n=== TESTING PROCESSOR ==="
processor = KrakenAccount::LedgerProcessor.new(kraken_account)
result = processor.process
puts "Processor result: #{result}"

puts "\n=== ENTRIES AFTER PROCESS ==="
kraken_entries = account.entries.where(source: "kraken")
puts "Total Kraken entries in account: #{kraken_entries.count}"

kraken_entries.order(date: :desc).each do |entry|
  puts "  - #{entry.date}: #{entry.name} (#{entry.entryable_type})"
  puts "    #{entry.amount} #{entry.currency} | external_id: #{entry.external_id}"
end

puts "\nDone!"
