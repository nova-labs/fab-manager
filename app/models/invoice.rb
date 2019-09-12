# frozen_string_literal: true

require 'checksum'

# Invoice correspond to a single purchase made by an user. This purchase may
# include reservation(s) and/or a subscription
class Invoice < ActiveRecord::Base
  include NotifyWith::NotificationAttachedObject
  require 'fileutils'
  scope :only_invoice, -> { where(type: nil) }
  belongs_to :invoiced, polymorphic: true

  has_many :invoice_items, dependent: :destroy
  accepts_nested_attributes_for :invoice_items
  belongs_to :invoicing_profile
  belongs_to :statistic_profile
  belongs_to :wallet_transaction
  belongs_to :coupon

  belongs_to :subscription, foreign_type: 'Subscription', foreign_key: 'invoiced_id'
  belongs_to :reservation, foreign_type: 'Reservation', foreign_key: 'invoiced_id'
  belongs_to :offer_day, foreign_type: 'OfferDay', foreign_key: 'invoiced_id'

  has_one :avoir, class_name: 'Invoice', foreign_key: :invoice_id, dependent: :destroy
  belongs_to :operator_profile, foreign_key: :operator_profile_id, class_name: 'InvoicingProfile'

  before_create :add_environment
  after_create :update_reference, :chain_record
  after_commit :generate_and_send_invoice, on: [:create], if: :persisted?
  after_update :log_changes

  validates_with ClosedPeriodValidator

  def file
    dir = "invoices/#{invoicing_profile.id}"

    # create directories if they doesn't exists (invoice & invoicing_profile_id)
    FileUtils.mkdir_p dir
    "#{dir}/#{filename}"
  end

  def filename
    "#{ENV['INVOICE_PREFIX']}-#{id}_#{created_at.strftime('%d%m%Y')}.pdf"
  end

  def user
    invoicing_profile.user
  end

  def generate_reference
    pattern = Setting.find_by(name: 'invoice_reference').value

    # invoice number per day (dd..dd)
    reference = pattern.gsub(/d+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('day'), match.to_s.length)
    end
    # invoice number per month (mm..mm)
    reference.gsub!(/m+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('month'), match.to_s.length)
    end
    # invoice number per year (yy..yy)
    reference.gsub!(/y+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('year'), match.to_s.length)
    end

    # full year (YYYY)
    reference.gsub!(/YYYY(?![^\[]*\])/, Time.now.strftime('%Y'))
    # year without century (YY)
    reference.gsub!(/YY(?![^\[]*\])/, Time.now.strftime('%y'))

    # abreviated month name (MMM)
    reference.gsub!(/MMM(?![^\[]*\])/, Time.now.strftime('%^b'))
    # month of the year, zero-padded (MM)
    reference.gsub!(/MM(?![^\[]*\])/, Time.now.strftime('%m'))
    # month of the year, non zero-padded (M)
    reference.gsub!(/M(?![^\[]*\])/, Time.now.strftime('%-m'))

    # day of the month, zero-padded (DD)
    reference.gsub!(/DD(?![^\[]*\])/, Time.now.strftime('%d'))
    # day of the month, non zero-padded (DD)
    reference.gsub!(/DD(?![^\[]*\])/, Time.now.strftime('%-d'))

    # information about online selling (X[text])
    if paid_with_stripe?
      reference.gsub!(/X\[([^\]]+)\]/, '\1')
    else
      reference.gsub!(/X\[([^\]]+)\]/, ''.to_s)
    end

    # information about wallet (W[text])
    # reference.gsub!(/W\[([^\]]+)\]/, ''.to_s)

    # remove information about refunds (R[text])
    reference.gsub!(/R\[([^\]]+)\]/, ''.to_s)

    self.reference = reference
  end

  def update_reference
    generate_reference
    save
  end

  def order_number
    pattern = Setting.find_by(name: 'invoice_order-nb').value

    # global invoice number (nn..nn)
    reference = pattern.gsub(/n+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('global'), match.to_s.length)
    end
    # invoice number per year (yy..yy)
    reference.gsub!(/y+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('year'), match.to_s.length)
    end
    # invoice number per month (mm..mm)
    reference.gsub!(/m+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('month'), match.to_s.length)
    end
    # invoice number per day (dd..dd)
    reference.gsub!(/d+(?![^\[]*\])/) do |match|
      pad_and_truncate(number_of_invoices('day'), match.to_s.length)
    end

    # full year (YYYY)
    reference.gsub!(/YYYY(?![^\[]*\])/, created_at.strftime('%Y'))
    # year without century (YY)
    reference.gsub!(/YY(?![^\[]*\])/, created_at.strftime('%y'))

    # abbreviated month name (MMM)
    reference.gsub!(/MMM(?![^\[]*\])/, created_at.strftime('%^b'))
    # month of the year, zero-padded (MM)
    reference.gsub!(/MM(?![^\[]*\])/, created_at.strftime('%m'))
    # month of the year, non zero-padded (M)
    reference.gsub!(/M(?![^\[]*\])/, created_at.strftime('%-m'))

    # day of the month, zero-padded (DD)
    reference.gsub!(/DD(?![^\[]*\])/, created_at.strftime('%d'))
    # day of the month, non zero-padded (DD)
    reference.gsub!(/DD(?![^\[]*\])/, created_at.strftime('%-d'))

    reference
  end

  # for debug & used by rake task "fablab:maintenance:regenerate_invoices"
  def regenerate_invoice_pdf
    pdf = ::PDF::Invoice.new(self, subscription&.expiration_date).render
    File.binwrite(file, pdf)
  end

  def build_avoir(attrs = {})
    raise Exception if refunded? === true || prevent_refund?

    avoir = Avoir.new(dup.attributes)
    avoir.type = 'Avoir'
    avoir.attributes = attrs
    avoir.reference = nil
    avoir.invoice_id = id
    # override created_at to compute CA in stats
    avoir.created_at = avoir.avoir_date
    avoir.total = 0
    # refunds of invoices with cash coupons: we need to ventilate coupons on paid items
    paid_items = 0
    refund_items = 0
    invoice_items.each do |ii|
      paid_items += 1 unless ii.amount.zero?
      next unless attrs[:invoice_items_ids].include? ii.id # list of items to refund (partial refunds)
      raise Exception if ii.invoice_item # cannot refund an item that was already refunded

      refund_items += 1 unless ii.amount.zero?
      avoir_ii = avoir.invoice_items.build(ii.dup.attributes)
      avoir_ii.created_at = avoir.avoir_date
      avoir_ii.invoice_item_id = ii.id
      avoir.total += avoir_ii.amount
    end
    # handle coupon
    unless avoir.coupon_id.nil?
      discount = avoir.total
      if avoir.coupon.type == 'percent_off'
        discount = avoir.total * avoir.coupon.percent_off / 100.0
      elsif avoir.coupon.type == 'amount_off'
        discount = (avoir.coupon.amount_off / paid_items) * refund_items
      else
        raise InvalidCouponError
      end
      avoir.total -= discount
    end
    avoir
  end

  def subscription_invoice?
    invoice_items.each do |ii|
      return true if ii.subscription
    end
    false
  end

  ##
  # Test if the current invoice has been refund, totally or partially.
  # @return {Boolean|'partial'}, true means fully refund, false means not refunded
  ##
  def refunded?
    if avoir
      invoice_items.each do |item|
        return 'partial' unless item.invoice_item
      end
      true
    else
      false
    end
  end

  ##
  # Check if the current invoice is about a training that was previously validated for the concerned user.
  # In that case refunding the invoice shouldn't be allowed.
  # Moreover, an invoice cannot be refunded if the users' account was deleted
  # @return {Boolean}
  ##
  def prevent_refund?
    return true if user.nil?

    if invoiced_type == 'Reservation' && invoiced.reservable_type == 'Training'
      user.trainings.include?(invoiced.reservable_id)
    else
      false
    end
  end

  # get amount total paid
  def amount_paid
    total - (wallet_amount || 0)
  end

  def add_environment
    self.environment = Rails.env
  end

  def chain_record
    self.footprint = compute_footprint
    save!
  end

  def check_footprint
    invoice_items.map(&:check_footprint).all? && footprint == compute_footprint
  end

  def set_wallet_transaction(amount, transaction_id)
    if check_footprint
      update_columns(wallet_amount: amount, wallet_transaction_id: transaction_id)
      chain_record
    else
      raise InvalidFootprintError
    end
  end

  def paid_with_stripe?
    stp_payment_intent_id? || stp_invoice_id?
  end

  private

  def generate_and_send_invoice
    unless Rails.env.test?
      puts "Creating an InvoiceWorker job to generate the following invoice: id(#{id}), invoiced_id(#{invoiced_id}), " \
           "invoiced_type(#{invoiced_type}), user_id(#{invoicing_profile.user_id})"
    end
    InvoiceWorker.perform_async(id, user&.subscription&.expired_at)
  end

  ##
  # Output the given integer with leading zeros. If the given value is longer than the given
  # length, it will be truncated.
  # @param value {Integer} the integer to pad
  # @param length {Integer} the length of the resulting string.
  ##
  def pad_and_truncate(value, length)
    value.to_s.rjust(length, '0').gsub(/^.*(.{#{length},}?)$/m, '\1')
  end

  ##
  # Returns the number of current invoices in the given range around the current date.
  # If range is invalid or not specified, the total number of invoices is returned.
  # @param range {String} 'day', 'month', 'year'
  # @return {Integer}
  ##
  def number_of_invoices(range)
    case range.to_s
    when 'day'
      start = DateTime.current.beginning_of_day
      ending = DateTime.current.end_of_day
    when 'month'
      start = DateTime.current.beginning_of_month
      ending = DateTime.current.end_of_month
    when 'year'
      start = DateTime.current.beginning_of_year
      ending = DateTime.current.end_of_year
    else
      return id
    end
    return Invoice.count unless defined? start && defined? ending

    Invoice.where('created_at >= :start_date AND created_at < :end_date', start_date: start, end_date: ending).length
  end

  def compute_footprint
    previous = Invoice.where('id < ?', id)
                      .order('id DESC')
                      .limit(1)

    columns  = Invoice.columns.map(&:name)
                      .delete_if { |c| %w[footprint updated_at].include? c }

    Checksum.text("#{columns.map { |c| self[c] }.join}#{previous.first ? previous.first.footprint : ''}")
  end

  def log_changes
    return if Rails.env.test?
    return unless changed?

    puts "WARNING: Invoice update triggered [ id: #{id}, reference: #{reference} ]"
    puts '----------   changes   ----------'
    puts changes
    puts '---------------------------------'
  end

end
