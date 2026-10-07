#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "jwt"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com"
APP_IDENTIFIER = ENV.fetch("APP_IDENTIFIER")
APPLY = ENV.fetch("APPLY", "false").casecmp?("true")

PRODUCTS = [
  { id: "cathedralos.credits.small", name: "StoryDonkey 20 Credits", type: "CONSUMABLE", price: "0.99", credits: 20 },
  { id: "cathedralos.credits.medium", name: "StoryDonkey 60 Credits", type: "CONSUMABLE", price: "2.99", credits: 60 },
  { id: "cathedralos.credits.large", name: "StoryDonkey 150 Credits", type: "CONSUMABLE", price: "6.99", credits: 150 },
  { id: "cathedralos.credits.xlarge", name: "StoryDonkey 400 Credits", type: "CONSUMABLE", price: "14.99", credits: 400 }
].freeze

PRO_MONTHLY = { id: "cathedralos.pro.monthly", price: "4.99" }.freeze

class ASCClient
  def initialize
    key = OpenSSL::PKey::EC.new(Base64.decode64(ENV.fetch("ASC_API_KEY")))
    payload = { iss: ENV.fetch("ASC_ISSUER_ID"), iat: Time.now.to_i - 60, exp: Time.now.to_i + 900, aud: "appstoreconnect-v1" }
    @token = JWT.encode(payload, key, "ES256", { kid: ENV.fetch("ASC_KEY_ID"), typ: "JWT" })
  end

  def request(method, path, body = nil)
    uri = URI.join(API_ROOT, path)
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
    return parsed if response.code.to_i.between?(200, 299)

    detail = parsed.dig("errors", 0, "detail") || parsed.dig("errors", 0, "title") || response.body
    raise "ASC API #{response.code} #{method} #{path}: #{detail}"
  end
end

def included_price_point(client, iap_id, target_price)
  response = client.request("get", "/v2/inAppPurchases/#{iap_id}/pricePoints?filter[territory]=USA&limit=8000")
  point = response.fetch("data").find { |item| item.dig("attributes", "customerPrice").to_s == target_price }
  raise "No USA price point found for $#{target_price} on #{iap_id}" unless point

  point
end

def create_price_schedule(client, iap_id, point_id)
  inline_price_id = "${price}"
  client.request("post", "/v1/inAppPurchasePriceSchedules", {
    data: {
      type: "inAppPurchasePriceSchedules",
      relationships: {
        baseTerritory: { data: { type: "territories", id: "USA" } },
        inAppPurchase: { data: { type: "inAppPurchases", id: iap_id } },
        manualPrices: { data: [{ type: "inAppPurchasePrices", id: inline_price_id }] }
      }
    },
    included: [{
      type: "inAppPurchasePrices",
      id: inline_price_id,
      relationships: {
        inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap_id } },
        inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point_id } }
      }
    }]
  })
end

client = ASCClient.new
app_response = client.request("get", "/v1/apps?filter[bundleId]=#{URI.encode_www_form_component(APP_IDENTIFIER)}")
app = app_response.fetch("data").first or raise "No App Store Connect app found for #{APP_IDENTIFIER}"
app_id = app.fetch("id")
products = client.request("get", "/v1/apps/#{app_id}/inAppPurchasesV2?include=iapPriceSchedule&limit=200").fetch("data")
by_product_id = products.to_h { |item| [item.dig("attributes", "productId"), item] }

puts "App Store Connect app #{app_id} (#{APP_IDENTIFIER})"
puts "Mode: #{APPLY ? "apply" : "audit"}"
puts "UNCHANGED #{PRO_MONTHLY[:id]} target=$#{PRO_MONTHLY[:price]} (auto-renewable subscription; Apple exposes it through the subscription API, not inAppPurchasesV2)"

PRODUCTS.each do |definition|
  item = by_product_id[definition[:id]]
  if item.nil?
    puts "MISSING #{definition[:id]} target=$#{definition[:price]} credits=#{definition[:credits]}"
    next unless APPLY
    raise "Refusing to create missing auto-renewable subscription #{definition[:id]}" if definition[:type] == "AUTORENEWABLE"

    item = client.request("post", "/v2/inAppPurchases", {
      data: {
        type: "inAppPurchases",
        attributes: {
          name: definition[:name],
          productId: definition[:id],
          inAppPurchaseType: definition[:type],
          familySharable: false,
          reviewNote: "StoryDonkey consumable credit pack: #{definition[:credits]} credits."
        },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }).fetch("data")
    by_product_id[definition[:id]] = item
    puts "CREATED #{definition[:id]} id=#{item.fetch("id")}" 

    client.request("post", "/v1/inAppPurchaseLocalizations", {
      data: {
        type: "inAppPurchaseLocalizations",
        attributes: {
          locale: "en-US",
          name: definition[:name],
          description: "One-time purchase of #{definition[:credits]} StoryDonkey generation credits."
        },
        relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: item.fetch("id") } } }
      }
    })
    puts "LOCALIZED #{definition[:id]} en-US"
  end

  point = included_price_point(client, item.fetch("id"), definition[:price])
  puts "READY #{definition[:id]} id=#{item.fetch("id")} target=$#{definition[:price]} price_point=#{point.fetch("id")}"
  next unless APPLY

  schedule = item.dig("relationships", "iapPriceSchedule", "data")
  if schedule
    puts "PRICE_SCHEDULE_EXISTS #{definition[:id]} (left unchanged)"
  else
    raise "No existing price schedule for #{definition[:id]} in audit mode" unless APPLY

    create_price_schedule(client, item.fetch("id"), point.fetch("id"))
    puts "PRICE_SCHEDULE_CREATED #{definition[:id]} $#{definition[:price]}"
  end
end
